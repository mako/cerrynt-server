# frozen_string_literal: true

require "rails_helper"
require "ipaddr"

RSpec.describe Feeds::Refresh do
  include ActiveSupport::Testing::TimeHelpers

  let(:feed) { create(:feed, url: "https://example.com/feed.xml", title: "Original Title", site_url: "https://example.com") }

  def build_fetch_result(
    success: true,
    error: nil,
    message: nil,
    title: "Updated Title",
    site_url: "https://example.com/site",
    etag: '"etag-123"',
    last_modified: "Wed, 21 Oct 2026 07:28:00 GMT",
    entries: []
  )
    feed_data = Feeds::Fetcher::ParsedFeed.new(
      title: title,
      site_url: site_url,
      entries: entries
    )

    Feeds::Fetcher::Result.new(
      success: success,
      error: error,
      message: message,
      status: success ? 200 : 500,
      final_url: "https://example.com/final_feed.xml",
      etag: etag,
      last_modified: last_modified,
      feed: success ? feed_data : nil
    )
  end

  def build_entry(
    guid: "guid-1",
    url: "https://example.com/posts/1",
    title: "Post 1",
    author: "Alice",
    summary: "Summary of post 1",
    content: "<p>Full content of post 1</p>",
    published_at: 1.day.ago
  )
    Feeds::Fetcher::ParsedEntry.new(
      guid: guid,
      url: url,
      title: title,
      author: author,
      summary: summary,
      content: content,
      published_at: published_at
    )
  end

  describe ".call" do
    it "creates entries and updates all feed metadata fields on first refresh" do
      entry1 = build_entry(guid: "g-1", url: "https://example.com/1", title: "First")
      entry2 = build_entry(guid: "g-2", url: "https://example.com/2", title: "Second")
      fetch_result = build_fetch_result(entries: [ entry1, entry2 ])

      frozen_time = Time.zone.parse("2026-10-12 12:00:00")
      result = travel_to(frozen_time) do
        described_class.call(feed, fetcher: ->(_url) { fetch_result })
      end

      expect(result).to be_ok
      expect(result.error).to be_nil
      expect(result.created).to eq(2)
      expect(result.updated).to eq(0)
      expect(result.skipped).to eq(0)
      expect(result.feed).to eq(feed)

      feed.reload
      expect(feed.title).to eq("Updated Title")
      expect(feed.site_url).to eq("https://example.com/site")
      expect(feed.etag).to eq('"etag-123"')
      expect(feed.last_modified).to eq("Wed, 21 Oct 2026 07:28:00 GMT")
      expect(feed.last_fetched_at).to eq(frozen_time)
      expect(feed.last_success_at).to eq(frozen_time)
      expect(feed.consecutive_failures).to eq(0)
      expect(feed.status).to eq("active")
      expect(feed.url).to eq("https://example.com/feed.xml")

      expect(feed.entries.count).to eq(2)
      first = feed.entries.find_by(guid: "g-1")
      expect(first.title).to eq("First")
      expect(first.url).to eq("https://example.com/1")
      expect(first.created_at).to eq(frozen_time)
      expect(first.updated_at).to eq(frozen_time)
    end

    it "changes nothing when refreshing the same result again" do
      entry = build_entry(guid: "g-1", url: "https://example.com/1", title: "First")
      fetch_result = build_fetch_result(entries: [ entry ])

      initial_time = Time.zone.parse("2026-10-12 10:00:00")
      travel_to(initial_time) do
        described_class.call(feed, fetcher: ->(_url) { fetch_result })
      end

      feed_entry = feed.entries.find_by(guid: "g-1")
      original_updated_at = feed_entry.updated_at

      later_time = Time.zone.parse("2026-10-12 11:00:00")
      result = travel_to(later_time) do
        described_class.call(feed, fetcher: ->(_url) { fetch_result })
      end

      expect(result).to be_ok
      expect(result.created).to eq(0)
      expect(result.updated).to eq(0)
      expect(result.skipped).to eq(0)

      feed_entry.reload
      expect(feed_entry.updated_at).to eq(original_updated_at)
    end

    it "updates changed entries and bumps updated_at while keeping unchanged siblings intact" do
      entry1 = build_entry(guid: "g-1", title: "Original 1")
      entry2 = build_entry(guid: "g-2", title: "Original 2")
      fetch_result1 = build_fetch_result(entries: [ entry1, entry2 ])

      initial_time = Time.zone.parse("2026-10-12 10:00:00")
      travel_to(initial_time) do
        described_class.call(feed, fetcher: ->(_url) { fetch_result1 })
      end

      e1 = feed.entries.find_by(guid: "g-1")
      e2 = feed.entries.find_by(guid: "g-2")
      e1_orig_updated = e1.updated_at
      e2_orig_updated = e2.updated_at

      # entry 1 is modified; entry 2 is unchanged
      entry1_modified = build_entry(guid: "g-1", title: "Modified Title 1")
      fetch_result2 = build_fetch_result(entries: [ entry1_modified, entry2 ])

      later_time = Time.zone.parse("2026-10-12 11:00:00")
      result = travel_to(later_time) do
        described_class.call(feed, fetcher: ->(_url) { fetch_result2 })
      end

      expect(result.created).to eq(0)
      expect(result.updated).to eq(1)

      e1.reload
      e2.reload
      expect(e1.title).to eq("Modified Title 1")
      expect(e1.updated_at).to eq(later_time)
      expect(e1.updated_at).not_to eq(e1_orig_updated)

      expect(e2.title).to eq("Original 2")
      expect(e2.updated_at).to eq(e2_orig_updated)
    end

    it "adds new entries next to existing ones" do
      entry1 = build_entry(guid: "g-1")
      described_class.call(feed, fetcher: ->(_url) { build_fetch_result(entries: [ entry1 ]) })
      expect(feed.entries.count).to eq(1)

      entry2 = build_entry(guid: "g-2")
      result = described_class.call(feed, fetcher: ->(_url) { build_fetch_result(entries: [ entry1, entry2 ]) })

      expect(result.created).to eq(1)
      expect(result.updated).to eq(0)
      expect(feed.entries.count).to eq(2)
      expect(feed.entries.pluck(:guid)).to contain_exactly("g-1", "g-2")
    end

    it "preserves entry_states across entry updates" do
      user = create(:user)
      entry = build_entry(guid: "g-1", title: "Old Title")
      described_class.call(feed, fetcher: ->(_url) { build_fetch_result(entries: [ entry ]) })

      db_entry = feed.entries.find_by(guid: "g-1")
      state = create(:entry_state, user: user, entry: db_entry, read_at: 1.day.ago, starred_at: 1.day.ago)
      orig_read_at = state.read_at
      orig_starred_at = state.starred_at

      updated_entry = build_entry(guid: "g-1", title: "New Title")
      result = described_class.call(feed, fetcher: ->(_url) { build_fetch_result(entries: [ updated_entry ]) })

      expect(result.updated).to eq(1)
      state.reload
      expect(state.entry_id).to eq(db_entry.id)
      expect(state.read_at).to eq(orig_read_at)
      expect(state.starred_at).to eq(orig_starred_at)
    end

    it "counts rows actually inserted when a concurrent insert creates a conflict" do
      entry1 = build_entry(guid: "concurrent-guid-1", title: "New Entry 1")
      entry2 = build_entry(guid: "concurrent-guid-2", title: "New Entry 2")
      fetch_result = build_fetch_result(entries: [ entry1, entry2 ])

      allow(Entry).to receive(:insert_all).and_wrap_original do |original_method, records, **kwargs|
        create(:entry, feed: feed, guid: "concurrent-guid-1", title: "Concurrent Winner")
        original_method.call(records, **kwargs)
      end

      result = nil
      expect {
        result = described_class.call(feed, fetcher: ->(_url) { fetch_result })
      }.not_to raise_error

      expect(result.created).to eq(1)
      expect(feed.entries.count).to eq(2)
      winner = feed.entries.find_by(guid: "concurrent-guid-1")
      expect(winner.title).to eq("Concurrent Winner")
      second = feed.entries.find_by(guid: "concurrent-guid-2")
      expect(second.title).to eq("New Entry 2")
    end

    describe "URL validation, schemes, and fallbacks" do
      it "skips and counts entries with javascript:, data:, and file: schemes when guid is not an http URL" do
        e1 = build_entry(guid: "g-1", url: "javascript:alert(1)")
        e2 = build_entry(guid: "g-2", url: "data:text/html;base64,PHNjcmlwdD4=")
        e3 = build_entry(guid: "g-3", url: "file:///etc/passwd")
        e4 = build_entry(guid: "g-4", url: "https://example.com/valid")

        result = described_class.call(feed, fetcher: ->(_url) { build_fetch_result(entries: [ e1, e2, e3, e4 ]) })

        expect(result.created).to eq(1)
        expect(result.skipped).to eq(3)
        expect(feed.entries.count).to eq(1)
        expect(feed.entries.first.guid).to eq("g-4")
      end

      it "falls back to a usable http guid when entry url is longer than 2048 characters" do
        too_long_url = "https://example.com/" + ("a" * 2050)
        entry = build_entry(guid: "https://example.com/fallback-guid", url: too_long_url)

        result = described_class.call(feed, fetcher: ->(_url) { build_fetch_result(entries: [ entry ]) })

        expect(result.created).to eq(1)
        expect(result.skipped).to eq(0)
        saved = feed.entries.find_by(guid: "https://example.com/fallback-guid")
        expect(saved.url).to eq("https://example.com/fallback-guid")
      end

      it "skips an entry when entry url is longer than 2048 characters and guid is not a usable http URL" do
        too_long_url = "https://example.com/" + ("a" * 2050)
        entry = build_entry(guid: "urn:uuid:12345", url: too_long_url)

        result = described_class.call(feed, fetcher: ->(_url) { build_fetch_result(entries: [ entry ]) })

        expect(result.created).to eq(0)
        expect(result.skipped).to eq(1)
        expect(feed.entries.count).to eq(0)
      end

      it "rejects entry url with userinfo and falls back to usable guid or skips" do
        e_with_usable_guid = build_entry(guid: "https://example.com/clean-guid", url: "https://user:pass@example.com/item1")
        e_without_guid = build_entry(guid: "not-a-url", url: "https://user:pass@example.com/item2")

        result = described_class.call(feed, fetcher: ->(_url) { build_fetch_result(entries: [ e_with_usable_guid, e_without_guid ]) })

        expect(result.created).to eq(1)
        expect(result.skipped).to eq(1)
        expect(feed.entries.find_by(guid: "https://example.com/clean-guid").url).to eq("https://example.com/clean-guid")
      end

      it "falls back to an http guid when url is missing or invalid" do
        e_missing_url = build_entry(guid: "https://example.com/guid-is-url", url: nil)
        e_invalid_url = build_entry(guid: "http://example.com/guid-is-http", url: "javascript:void(0)")

        result = described_class.call(feed, fetcher: ->(_url) { build_fetch_result(entries: [ e_missing_url, e_invalid_url ]) })

        expect(result.created).to eq(2)
        expect(result.skipped).to eq(0)
        expect(feed.entries.find_by(guid: "https://example.com/guid-is-url").url).to eq("https://example.com/guid-is-url")
        expect(feed.entries.find_by(guid: "http://example.com/guid-is-http").url).to eq("http://example.com/guid-is-http")
      end

      it "skips and counts an entry when url is missing and guid is not an http URL" do
        entry = build_entry(guid: "urn:uuid:12345-not-http", url: nil)

        result = described_class.call(feed, fetcher: ->(_url) { build_fetch_result(entries: [ entry ]) })

        expect(result.created).to eq(0)
        expect(result.skipped).to eq(1)
        expect(feed.entries.count).to eq(0)
      end
    end

    describe "truncation limits and unusable field handling" do
      it "truncates title to 500 and author to 255 without failing" do
        long_title = "T" * 600
        long_author = "A" * 300
        entry = build_entry(guid: "g-1", url: "https://example.com/valid", title: long_title, author: long_author)

        result = described_class.call(feed, fetcher: ->(_url) { build_fetch_result(entries: [ entry ]) })

        expect(result.created).to eq(1)
        saved = feed.entries.find_by(guid: "g-1")
        expect(saved.title.length).to eq(500)
        expect(saved.author.length).to eq(255)
      end

      it "keeps old feed site_url if incoming site_url is longer than 2048 characters" do
        too_long_site_url = "https://example.com/" + ("s" * 2050)
        fetch_result = build_fetch_result(site_url: too_long_site_url, entries: [])

        described_class.call(feed, fetcher: ->(_url) { fetch_result })
        expect(feed.reload.site_url).to eq("https://example.com")
      end

      it "keeps old feed site_url if incoming site_url has userinfo" do
        fetch_result = build_fetch_result(site_url: "https://user:pass@example.com/site", entries: [])

        described_class.call(feed, fetcher: ->(_url) { fetch_result })
        expect(feed.reload.site_url).to eq("https://example.com")
      end

      it "truncates feed title to 500 and keeps old title if parsed title is blank" do
        long_feed_title = "F" * 600
        fetch_result = build_fetch_result(title: long_feed_title, entries: [])

        described_class.call(feed, fetcher: ->(_url) { fetch_result })
        expect(feed.reload.title.length).to eq(500)

        # Blank parsed title leaves old title intact
        fetch_blank = build_fetch_result(title: "   ", entries: [])
        described_class.call(feed, fetcher: ->(_url) { fetch_blank })
        expect(feed.reload.title.length).to eq(500)
      end

      it "keeps old feed site_url if parsed site_url is invalid" do
        fetch_invalid_site = build_fetch_result(site_url: "javascript:bad()", entries: [])
        described_class.call(feed, fetcher: ->(_url) { fetch_invalid_site })
        expect(feed.reload.site_url).to eq("https://example.com")
      end
    end

    describe "NUL and invalid UTF-8 scrubbing" do
      it "removes NUL bytes and scrubs invalid UTF-8 in strings" do
        dirty_title = "Hello\0\xFFWorld"
        dirty_author = "John\0Doe\xFE"
        dirty_summary = "<p>Summary\0with\xFDnulls</p>"
        dirty_content = "<div>Content\0with\xFCnulls</div>"

        entry = build_entry(
          guid: "g-1",
          title: dirty_title,
          author: dirty_author,
          summary: dirty_summary,
          content: dirty_content
        )

        result = described_class.call(feed, fetcher: ->(_url) { build_fetch_result(entries: [ entry ]) })

        expect(result.created).to eq(1)
        saved = feed.entries.find_by(guid: "g-1")
        expect(saved.title).to eq("Hello\uFFFDWorld")
        expect(saved.author).to eq("JohnDoe\uFFFD")
        expect(saved.summary).to eq("<p>Summarywith\uFFFDnulls</p>")
        expect(saved.content).to eq("<div>Contentwith\uFFFDnulls</div>")
      end
    end

    describe "GUID handling" do
      it "replaces guid longer than 500 characters with its SHA-256 hex digest consistently" do
        long_guid = "g" * 600
        expected_digest = Digest::SHA256.hexdigest(long_guid)

        entry = build_entry(guid: long_guid)
        result = described_class.call(feed, fetcher: ->(_url) { build_fetch_result(entries: [ entry ]) })

        expect(result.created).to eq(1)
        saved = feed.entries.first
        expect(saved.guid).to eq(expected_digest)
        expect(saved.guid.length).to eq(64)

        # Refreshing again finds the existing entry via the SHA-256 digest
        result2 = described_class.call(feed, fetcher: ->(_url) { build_fetch_result(entries: [ entry ]) })
        expect(result2.created).to eq(0)
        expect(result2.updated).to eq(0)
      end

      it "deduplicates entries with identical guids in the same batch with first winning" do
        entry_first = build_entry(guid: "dup-guid", title: "First Winning Title")
        entry_second = build_entry(guid: "dup-guid", title: "Second Ignored Title")

        result = described_class.call(feed, fetcher: ->(_url) { build_fetch_result(entries: [ entry_first, entry_second ]) })

        expect(result.created).to eq(1)
        expect(feed.entries.count).to eq(1)
        expect(feed.entries.first.title).to eq("First Winning Title")
      end
    end

    describe "published_at handling" do
      it "clamps future published_at to fetch time on insert and avoids churn until date passes" do
        t1 = Time.zone.parse("2026-10-12 10:00:00")
        future_time = Time.zone.parse("2026-10-12 12:00:00")
        entry = build_entry(guid: "g-1", published_at: future_time)

        # 1. First fetch at 10:00 clamps to fetch time (10:00) on insert
        travel_to(t1) do
          described_class.call(feed, fetcher: ->(_url) { build_fetch_result(entries: [ entry ]) })
        end

        saved = feed.entries.find_by(guid: "g-1")
        expect(saved.published_at).to eq(t1)
        orig_updated_at = saved.updated_at

        # 2. Second fetch at later time (11:00) while still in future leaves stored date untouched (no churn)
        t2 = Time.zone.parse("2026-10-12 11:00:00")
        result2 = travel_to(t2) do
          described_class.call(feed, fetcher: ->(_url) { build_fetch_result(entries: [ entry ]) })
        end

        expect(result2.updated).to eq(0)
        saved.reload
        expect(saved.published_at).to eq(t1)
        expect(saved.updated_at).to eq(orig_updated_at)

        # 3. Third fetch after date has passed (13:00) applies the real date exactly once
        t3 = Time.zone.parse("2026-10-12 13:00:00")
        result3 = travel_to(t3) do
          described_class.call(feed, fetcher: ->(_url) { build_fetch_result(entries: [ entry ]) })
        end

        expect(result3.updated).to eq(1)
        saved.reload
        expect(saved.published_at).to eq(future_time)
        expect(saved.updated_at).to eq(t3)

        # 4. Subsequent fetch after real date is applied leaves it untouched
        t4 = Time.zone.parse("2026-10-12 14:00:00")
        result4 = travel_to(t4) do
          described_class.call(feed, fetcher: ->(_url) { build_fetch_result(entries: [ entry ]) })
        end

        expect(result4.updated).to eq(0)
        saved.reload
        expect(saved.published_at).to eq(future_time)
      end

      it "uses fetch time on insert when published_at is missing" do
        now = Time.zone.parse("2026-10-12 12:00:00")
        entry = build_entry(guid: "g-1", published_at: nil)

        travel_to(now) do
          described_class.call(feed, fetcher: ->(_url) { build_fetch_result(entries: [ entry ]) })
        end

        saved = feed.entries.find_by(guid: "g-1")
        expect(saved.published_at).to eq(now)
      end

      it "keeps stored published_at on update when incoming published_at is missing" do
        initial_time = Time.zone.parse("2026-10-12 10:00:00")
        custom_published = Time.zone.parse("2026-10-01 10:00:00")
        entry = build_entry(guid: "g-1", title: "Old Title", published_at: custom_published)

        travel_to(initial_time) do
          described_class.call(feed, fetcher: ->(_url) { build_fetch_result(entries: [ entry ]) })
        end

        later_time = Time.zone.parse("2026-10-12 11:00:00")
        # Update with new title, but nil published_at
        entry_updated = build_entry(guid: "g-1", title: "New Title", published_at: nil)

        result = travel_to(later_time) do
          described_class.call(feed, fetcher: ->(_url) { build_fetch_result(entries: [ entry_updated ]) })
        end

        expect(result.updated).to eq(1)
        saved = feed.entries.find_by(guid: "g-1")
        expect(saved.title).to eq("New Title")
        expect(saved.published_at).to eq(custom_published)
      end
    end

    describe "fetch failure handling" do
      it "leaves feed and entries completely unchanged on failure Result" do
        feed.update!(
          title: "Initial Title",
          last_fetched_at: 1.day.ago,
          consecutive_failures: 2,
          status: "active"
        )
        orig_feed_attributes = feed.attributes

        entry = create(:entry, feed: feed, title: "Existing Entry")
        orig_entry_attributes = entry.attributes

        failed_result = build_fetch_result(
          success: false,
          error: :unreachable,
          message: "Feed host is unreachable"
        )

        result = described_class.call(feed, fetcher: ->(_url) { failed_result })

        expect(result).not_to be_ok
        expect(result.error).to eq(:unreachable)
        expect(result.message).to eq("Feed host is unreachable")
        expect(result.created).to eq(0)
        expect(result.updated).to eq(0)
        expect(result.skipped).to eq(0)

        expect(feed.reload.attributes).to eq(orig_feed_attributes)
        expect(entry.reload.attributes).to eq(orig_entry_attributes)
      end
    end

    describe "transaction atomicity" do
      it "propagates unexpected errors and leaves feed metadata unchanged when insert_all fails" do
        feed.update!(
          title: "Untouched Title",
          last_fetched_at: nil,
          consecutive_failures: 1
        )
        entry = build_entry(guid: "g-1")

        allow(Entry).to receive(:insert_all).and_raise(ActiveRecord::StatementInvalid.new("Simulated DB failure"))

        expect {
          described_class.call(feed, fetcher: ->(_url) { build_fetch_result(entries: [ entry ]) })
        }.to raise_error(ActiveRecord::StatementInvalid, /Simulated DB failure/)

        feed.reload
        expect(feed.title).to eq("Untouched Title")
        expect(feed.last_fetched_at).to be_nil
        expect(feed.consecutive_failures).to eq(1)
        expect(feed.entries.count).to eq(0)
      end
    end

    describe "query count efficiency" do
      it "issues a small constant number of SQL queries when refreshing 200 new entries" do
        entries_200 = Array.new(200) do |i|
          build_entry(guid: "batch-guid-#{i}", url: "https://example.com/posts/#{i}", title: "Post #{i}")
        end

        fetch_result = build_fetch_result(entries: entries_200)

        target_feed = feed # evaluate let(:feed) before measuring queries
        queries = []
        subscription = ActiveSupport::Notifications.subscribe("sql.active_record") do |_name, _start, _finish, _id, payload|
          sql = payload[:sql].to_s.strip
          name = payload[:name].to_s
          unless name == "SCHEMA" || name == "TRANSACTION" || sql =~ /\A(BEGIN|COMMIT|ROLLBACK|SAVEPOINT|RELEASE SAVEPOINT)\b/i
            queries << sql
          end
        end

        begin
          result = described_class.call(target_feed, fetcher: ->(_url) { fetch_result })
        ensure
          ActiveSupport::Notifications.unsubscribe(subscription)
        end

        expect(result.created).to eq(200)
        # Bounded constant query count:
        # 1. SELECT query to check for existing entries by guids
        # 2. Bulk INSERT query via Entry.insert_all
        # 3. SELECT uniqueness validation query on feeds (Feed#update! validates url uniqueness)
        # 4. UPDATE query on feeds table for metadata
        # Total is bounded at 4 queries.
        expect(queries.size).to be <= 4
        expect(target_feed.entries.count).to eq(200)
      end
    end

    describe "end-to-end integration" do
      it "persists 2 entries using real Feeds::Fetcher with rss20 fixture and fake resolver" do
        fixture_path = Rails.root.join("spec/fixtures/files/feeds/rss20.xml")
        xml_content = File.read(fixture_path)

        stub_request(:get, "https://example.com/feed.xml")
          .to_return(
            status: 200,
            headers: { "Content-Type" => "application/rss+xml", "ETag" => '"rss20-etag"' },
            body: xml_content
          )

        fake_resolver = ->(_host) { [ IPAddr.new("93.184.216.34") ] }
        fetcher = ->(url) { Feeds::Fetcher.call(url, resolver: fake_resolver) }

        result = described_class.call(feed, fetcher: fetcher)

        expect(result).to be_ok
        expect(result.created).to eq(2)
        expect(result.updated).to eq(0)
        expect(result.skipped).to eq(0)

        feed.reload
        expect(feed.title).to eq("Cerrynt RSS Feed")
        expect(feed.site_url).to eq("https://example.com/rss")
        expect(feed.etag).to eq('"rss20-etag"')
        expect(feed.entries.count).to eq(2)

        entry1 = feed.entries.find_by(guid: "item-1-guid")
        expect(entry1.title).to eq("First RSS Item")
        expect(entry1.url).to eq("https://example.com/items/1")
        expect(entry1.author).to eq("author@example.com (Alice)")
        expect(entry1.summary).to eq("Summary of first item")
        expect(entry1.content).to eq("<p>Full content of first item</p>")
        expect(entry1.published_at).to eq(Time.utc(2024, 1, 1, 12, 0, 0))

        entry2 = feed.entries.find_by(guid: "item-2-guid")
        expect(entry2.title).to eq("Second RSS Item")
        expect(entry2.url).to eq("https://example.com/items/2")
        expect(entry2.author).to eq("author@example.com (Bob)")
        expect(entry2.summary).to eq("Summary of second item")
        expect(entry2.published_at).to eq(Time.utc(2024, 1, 2, 12, 0, 0))
      end
    end
  end
end
