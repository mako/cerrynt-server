# frozen_string_literal: true

require "rails_helper"

RSpec.describe Opml::Import do
  include ActiveSupport::Testing::TimeHelpers

  def count_queries(&block)
    queries = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |_name, _start, _finish, _id, payload|
      sql = payload[:sql].to_s.strip
      name = payload[:name].to_s
      unless name == "SCHEMA" || name == "TRANSACTION" || sql.match?(/\A(BEGIN|COMMIT|ROLLBACK|SAVEPOINT|RELEASE)\b/i)
        queries << sql
      end
    end
    block.call
    queries.size
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end

  before do
    allow(Resolv).to receive(:getaddress).and_raise("Network/DNS call forbidden in Opml::Import")
    allow(Resolv).to receive(:getaddresses).and_raise("Network/DNS call forbidden in Opml::Import")
    allow(Addrinfo).to receive(:getaddrinfo).and_raise("Network/DNS call forbidden in Opml::Import")
    allow(Socket).to receive(:getaddrinfo).and_raise("Network/DNS call forbidden in Opml::Import")
    allow(TCPSocket).to receive(:open).and_raise("Network call forbidden in Opml::Import")
    allow(Net::HTTP).to receive(:start).and_raise("Network call forbidden in Opml::Import")
  end

  let(:free_user) { create(:user, plan: "free") }
  let(:pro_user) { create(:user, plan: "pro") }

  describe ".call" do
    context "with empty outlines" do
      it "returns imported 0, skipped 0, errors [] without running queries" do
        user = free_user
        result = count_queries do
          described_class.call(user: user, outlines: [])
        end

        expect(result).to eq(0)
        res = described_class.call(user: user, outlines: [])
        expect(res.imported).to eq(0)
        expect(res.skipped).to eq(0)
        expect(res.errors).to eq([])
      end
    end

    context "plan limit enforcement and feed row creation" do
      it "imports up to plan limit, emits feed_limit_reached errors in order, and creates feed rows only for subscribed candidates" do
        # Free user plan limit is 2
        expect(Plan.max_feeds_for("free")).to eq(2)

        outlines = (1..5).map do |i|
          { url: "https://example.com/feed#{i}.xml", title: "Feed #{i}" }
        end

        initial_feed_count = Feed.count

        result = described_class.call(user: free_user, outlines: outlines)

        expect(result.imported).to eq(2)
        expect(result.skipped).to eq(0)
        expect(result.errors.size).to eq(3)

        expect(result.errors).to eq([
          { url: "https://example.com/feed3.xml", code: "feed_limit_reached" },
          { url: "https://example.com/feed4.xml", code: "feed_limit_reached" },
          { url: "https://example.com/feed5.xml", code: "feed_limit_reached" }
        ])

        # Exactly 2 new feed rows exist; no orphan feeds for over-limit outlines
        expect(Feed.count).to eq(initial_feed_count + 2)
        expect(Feed.exists?(url: "https://example.com/feed1.xml")).to be true
        expect(Feed.exists?(url: "https://example.com/feed2.xml")).to be true
        expect(Feed.exists?(url: "https://example.com/feed3.xml")).to be false
        expect(Feed.exists?(url: "https://example.com/feed4.xml")).to be false
        expect(Feed.exists?(url: "https://example.com/feed5.xml")).to be false

        expect(free_user.subscriptions.count).to eq(2)
      end

      it "pro user imports all valid outlines within plan limit" do
        outlines = (1..5).map do |i|
          { url: "https://example.com/pro_feed#{i}.xml", title: "Feed #{i}" }
        end

        result = described_class.call(user: pro_user, outlines: outlines)

        expect(result.imported).to eq(5)
        expect(result.skipped).to eq(0)
        expect(result.errors).to be_empty
        expect(pro_user.subscriptions.count).to eq(5)
      end

      it "calls Plan.max_feeds_for to determine limit dynamically" do
        allow(Plan).to receive(:max_feeds_for).with("free").and_return(1)

        outlines = [
          { url: "https://example.com/dyn1.xml" },
          { url: "https://example.com/dyn2.xml" }
        ]

        result = described_class.call(user: free_user, outlines: outlines)

        expect(result.imported).to eq(1)
        expect(result.errors).to eq([
          { url: "https://example.com/dyn2.xml", code: "feed_limit_reached" }
        ])
      end

      it "returns submitted url (cut to 2048 chars, scrubbed) instead of normalized url for limit errors" do
        long_invalid_url = "https://example.com/" + ("a" * 2500)
        outlines = [
          { url: "https://example.com/sub1.xml" },
          { url: "https://example.com/sub2.xml" },
          { url: "HTTP://Example.com/feed#x" },
          { url: long_invalid_url }
        ]

        result = described_class.call(user: free_user, outlines: outlines)

        expect(result.imported).to eq(2)
        expect(result.errors).to eq([
          { url: "HTTP://Example.com/feed#x", code: "feed_limit_reached" },
          { url: long_invalid_url[0, 2048], code: "invalid_feed_url" }
        ])
      end

      it "stores scrubbed cut URL in Candidate without retaining invalid UTF-8 bytes" do
        allow(Feeds::UrlPolicy).to receive(:normalize_and_validate_feed_url) do |url|
          url.to_s.include?("bad") ? "https://example.com/bad.xml" : Feeds::UrlPolicy.normalize_feed_url(url)
        end
        raw_binary_url = "https://example.com/bad_\xFF".b
        outlines = [
          { url: "https://example.com/sub1.xml" },
          { url: "https://example.com/sub2.xml" },
          { url: raw_binary_url }
        ]

        result = described_class.call(user: free_user, outlines: outlines)

        expect(result.imported).to eq(2)
        limit_error = result.errors.find { |e| e[:code] == "feed_limit_reached" }
        expect(limit_error[:url]).to eq("https://example.com/bad_")
        expect(limit_error[:url].valid_encoding?).to be true
      end
    end

    context "URL normalization and deduplication" do
      it "normalizes URL variants (scheme/host case, fragment, empty path slash) and imports one, skipping the rest" do
        create(:subscription, user: free_user)
        outlines = [
          { url: "HTTPS://VARIANT.EXAMPLE.COM/feed.xml" },
          { url: "https://variant.example.com/feed.xml#fragment" },
          { url: "https://variant.example.com/feed.xml" },
          { url: "https://variant.example.com:443/feed.xml" }
        ]

        result = described_class.call(user: free_user, outlines: outlines)

        expect(result.imported).to eq(1)
        expect(result.skipped).to eq(3)
        expect(result.errors).to be_empty
        expect(Feed.where(url: "https://variant.example.com/feed.xml").count).to eq(1)
      end

      it "deduplicates in-file duplicates without creating duplicate feeds or subscriptions" do
        outlines = [
          { url: "https://example.com/dup.xml", title: "First Occurrence" },
          { url: "https://example.com/dup.xml", title: "Second Occurrence" }
        ]

        result = described_class.call(user: pro_user, outlines: outlines)

        expect(result.imported).to eq(1)
        expect(result.skipped).to eq(1)
        expect(result.errors).to be_empty
      end
    end

    context "already followed feeds and existing feeds" do
      it "skips an already-followed feed without emitting a limit error even when the user is at the limit" do
        # Fill free user limit
        feed1 = create(:feed, url: "https://example.com/existing1.xml")
        feed2 = create(:feed, url: "https://example.com/existing2.xml")
        create(:subscription, user: free_user, feed: feed1)
        create(:subscription, user: free_user, feed: feed2)
        expect(free_user.subscriptions.count).to eq(2)

        outlines = [
          { url: "https://example.com/existing1.xml" },
          { url: "https://example.com/brand_new.xml" }
        ]

        result = described_class.call(user: free_user, outlines: outlines)

        expect(result.imported).to eq(0)
        expect(result.skipped).to eq(1)
        expect(result.errors).to eq([
          { url: "https://example.com/brand_new.xml", code: "feed_limit_reached" }
        ])
      end

      it "subscribes to an already existing feed of another user without changing feed row count or feed metadata" do
        existing_feed = create(
          :feed,
          url: "https://example.com/shared.xml",
          title: "Untouched Title",
          site_url: "https://example.com/untouched"
        )
        other_user = create(:user)
        create(:subscription, user: other_user, feed: existing_feed)

        outlines = [
          {
            url: "https://example.com/shared.xml",
            title: "Overwriting Title Attempt",
            html_url: "https://example.com/overwriting"
          }
        ]

        expect {
          result = described_class.call(user: free_user, outlines: outlines)
          expect(result.imported).to eq(1)
          expect(result.skipped).to eq(0)
          expect(result.errors).to be_empty
        }.not_to change(Feed, :count)

        existing_feed.reload
        expect(existing_feed.title).to eq("Untouched Title")
        expect(existing_feed.site_url).to eq("https://example.com/untouched")
        expect(free_user.subscriptions.find_by(feed: existing_feed)).to be_present
      end

      it "stores provisional title and site_url for newly created feeds, silently dropping invalid html_url" do
        outlines = [
          {
            url: "https://example.com/new1.xml",
            title: "Provisional 1",
            html_url: "https://example.com/site1"
          },
          {
            url: "https://example.com/new2.xml",
            title: "Provisional 2",
            html_url: "javascript:bad_exploit()"
          }
        ]

        result = described_class.call(user: pro_user, outlines: outlines)

        expect(result.imported).to eq(2)
        feed1 = Feed.find_by!(url: "https://example.com/new1.xml")
        feed2 = Feed.find_by!(url: "https://example.com/new2.xml")

        expect(feed1.title).to eq("Provisional 1")
        expect(feed1.site_url).to eq("https://example.com/site1")

        expect(feed2.title).to eq("Provisional 2")
        expect(feed2.site_url).to be_nil
      end
    end

    context "invalid URLs and error handling" do
      it "rejects invalid URLs with invalid_feed_url code and cuts error url to 2048 chars without creating rows" do
        too_long_url = "https://example.com/" + ("x" * 2050)
        invalid_outlines = [
          { url: "ftp://example.com/feed.xml" },
          { url: "javascript:alert(1)" },
          { url: too_long_url },
          { url: "https://user:pass@example.com/feed.xml" },
          { url: "https://example.com:8080/feed.xml" },
          { url: "not-a-valid-url" },
          { url: "/relative/path.xml" }
        ]

        expect {
          result = described_class.call(user: pro_user, outlines: invalid_outlines)

          expect(result.imported).to eq(0)
          expect(result.skipped).to eq(0)
          expect(result.errors.size).to eq(7)

          result.errors.each do |err|
            expect(err[:code]).to eq("invalid_feed_url")
            expect(err[:url].length).to be <= 2048
          end

          expect(result.errors[2][:url].length).to eq(2048)
          expect(result.errors[2][:url]).to eq(too_long_url[0, 2048])
        }.not_to change(Feed, :count)
      end

      it "preserves document order of errors when mixing pre-pass invalid errors and plan-limit errors" do
        # Free user limit 2
        outlines = [
          { url: "https://example.com/valid1.xml" },    # imported 1
          { url: "javascript:exploit()" },              # pre-pass error at index 1
          { url: "https://example.com/valid2.xml" },    # imported 2 (limit full)
          { url: "https://example.com/valid1.xml" },    # skipped duplicate at index 3
          { url: "https://example.com/valid3.xml" },    # limit error at index 4
          { url: "ftp://example.com/invalid.xml" },     # pre-pass error at index 5
          { url: "https://example.com/valid4.xml" }     # limit error at index 6
        ]

        result = described_class.call(user: free_user, outlines: outlines)

        expect(result.imported).to eq(2)
        expect(result.skipped).to eq(1)
        expect(result.errors.size).to eq(4)
        expect(result.imported + result.skipped + result.errors.size).to eq(outlines.size)

        expect(result.errors).to eq([
          { url: "javascript:alert(1)", code: "invalid_feed_url" }.merge(url: "javascript:exploit()"),
          { url: "https://example.com/valid3.xml", code: "feed_limit_reached" },
          { url: "ftp://example.com/invalid.xml", code: "invalid_feed_url" },
          { url: "https://example.com/valid4.xml", code: "feed_limit_reached" }
        ])
      end

      it "ensures error items contain only :url and :code as plain Strings" do
        outlines = [
          { url: "invalid_url" }
        ]

        result = described_class.call(user: free_user, outlines: outlines)
        expect(result.errors.size).to eq(1)
        err = result.errors.first
        expect(err.keys).to contain_exactly(:url, :code)
        expect(err[:url]).to be_a(String)
        expect(err[:code]).to be_a(String)
      end
    end

    context "transaction integrity, user lock, and timestamps" do
      it "ensures BEGIN precedes the time read, and the user lock query precedes the limit count" do
        events = []
        callback = ->(_name, _start, _finish, _id, payload) do
          sql = payload[:sql].to_s.strip
          events << :begin if sql.match?(/\A(BEGIN|SAVEPOINT)\b/i)
          events << :count_query if sql.match?(/SELECT COUNT\(\*\) FROM ["`]subscriptions["`]/i)
        end
        allow(free_user).to receive(:lock!).and_wrap_original { |orig| events << :user_lock; orig.call }
        allow(Time).to receive(:current).and_wrap_original { |orig| events << :time_current; orig.call }

        ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
          result = described_class.call(user: free_user, outlines: [ { url: "https://example.com/event_feed.xml" } ])
          expect(result.imported).to eq(1)
        end

        expect(events.index(:begin)).not_to be_nil
        expect(events.index(:time_current)).to be > events.index(:begin)
        expect(events.index(:user_lock)).to be > events.index(:time_current)
        expect(events.index(:count_query)).to be > events.index(:user_lock)
      end

      it "sets next_fetch_at, created_at, updated_at of feeds and subscriptions to the exact yielded now" do
        fixed_time = Time.utc(2026, 10, 24, 12, 0, 0)

        allow(ApplicationRecord).to receive(:write_transaction).and_wrap_original do |original, &block|
          original.call do |_now|
            block.call(fixed_time)
          end
        end

        outlines = [ { url: "https://example.com/timestamped.xml" } ]
        result = described_class.call(user: free_user, outlines: outlines)
        expect(result.imported).to eq(1)

        feed = Feed.find_by!(url: "https://example.com/timestamped.xml")
        sub = free_user.subscriptions.find_by!(feed: feed)

        expect(feed.next_fetch_at).to eq(fixed_time)
        expect(feed.created_at).to eq(fixed_time)
        expect(feed.updated_at).to eq(fixed_time)

        expect(sub.created_at).to eq(fixed_time)
        expect(sub.updated_at).to eq(fixed_time)
      end

      it "creates subscriptions for the given user only, leaving other users untouched" do
        other_user = create(:user)
        outlines = [ { url: "https://example.com/exclusive.xml" } ]

        described_class.call(user: free_user, outlines: outlines)

        expect(free_user.subscriptions.count).to eq(1)
        expect(other_user.subscriptions.count).to eq(0)
      end

      it "rolls back created feeds if subscription insertion fails" do
        allow(Subscription).to receive(:insert_all).and_raise("Database failure simulation")

        outlines = [ { url: "https://example.com/rollback_target.xml" } ]

        expect {
          described_class.call(user: pro_user, outlines: outlines)
        }.to raise_error(RuntimeError, "Database failure simulation")

        expect(Feed.find_by(url: "https://example.com/rollback_target.xml")).to be_nil
        expect(pro_user.subscriptions.count).to eq(0)
      end
    end

    context "concurrent-writer simulations" do
      it "handles another user creating the same feed between pre-pass and feed insert" do
        feed_url = "https://example.com/concurrent_feed.xml"
        other_user = create(:user)

        allow(Feed).to receive(:insert_all).and_wrap_original do |original_method, records, **kwargs|
          # Concurrent writer creates the feed row right before insert_all
          Feed.create!(url: feed_url, title: "Concurrent Creator Title")
          original_method.call(records, **kwargs)
        end

        outlines = [ { url: feed_url, title: "Import Title" } ]
        result = described_class.call(user: pro_user, outlines: outlines)

        expect(result.imported).to eq(1)
        expect(result.skipped).to eq(0)
        expect(result.errors).to be_empty

        expect(Feed.where(url: feed_url).count).to eq(1)
        expect(Feed.find_by(url: feed_url).title).to eq("Concurrent Creator Title")
        expect(pro_user.subscriptions.find_by(feed: Feed.find_by(url: feed_url))).to be_present
      end

      it "absorbs concurrency into skipped when a subscription row for the same user appears right before subscription insert" do
        feed_url = "https://example.com/concurrent_sub.xml"

        allow(Subscription).to receive(:insert_all).and_wrap_original do |original_method, records, **kwargs|
          first_rec = records.first
          # Pre-create the subscription row
          Subscription.create!(user_id: first_rec[:user_id], feed_id: first_rec[:feed_id])
          original_method.call(records, **kwargs)
        end

        outlines = [ { url: feed_url } ]
        result = described_class.call(user: pro_user, outlines: outlines)

        expect(result.imported).to eq(0)
        expect(result.skipped).to eq(1)
        expect(result.errors).to be_empty
        expect(pro_user.subscriptions.count).to eq(1)
      end
    end

    context "scale and performance" do
      it "imports exactly 500 outlines without SQLite variable limit errors" do
        allow(Plan).to receive(:max_feeds_for).with("pro").and_return(1000)

        outlines = (1..500).map do |i|
          { url: "https://example.com/scale_#{i}.xml", title: "Feed #{i}" }
        end

        result = described_class.call(user: pro_user, outlines: outlines)

        expect(result.imported).to eq(500)
        expect(result.skipped).to eq(0)
        expect(result.errors).to be_empty
        expect(pro_user.subscriptions.count).to eq(500)
      end

      it "executes a constant number of SQL queries for 5 vs 100 vs 500 outlines" do
        allow(Plan).to receive(:max_feeds_for).with("pro").and_return(2000)

        user_5 = create(:user, plan: "pro")
        user_100 = create(:user, plan: "pro")
        user_500 = create(:user, plan: "pro")

        outlines_5 = (1..5).map { |i| { url: "https://example.com/q5_#{i}.xml" } }
        outlines_100 = (1..100).map { |i| { url: "https://example.com/q100_#{i}.xml" } }
        outlines_500 = (1..500).map { |i| { url: "https://example.com/q500_#{i}.xml" } }

        queries_5 = count_queries { described_class.call(user: user_5, outlines: outlines_5) }
        queries_100 = count_queries { described_class.call(user: user_100, outlines: outlines_100) }
        queries_500 = count_queries { described_class.call(user: user_500, outlines: outlines_500) }

        expect(queries_5).to eq(6)
        expect(queries_100).to eq(queries_5)
        expect(queries_500).to eq(queries_5)
      end
    end

    context "network isolation" do
      it "never touches the network or DNS for a mixed import (valid, existing, invalid, over-limit)" do
        other_user = create(:user)
        existing_feed = create(:feed, url: "https://example.com/existing.xml")
        create(:subscription, user: other_user, feed: existing_feed)

        outlines = [
          { url: "https://example.com/existing.xml" },
          { url: "https://example.com/new1.xml" },
          { url: "https://example.com/new1.xml" },
          { url: "ftp://example.com/invalid.xml" },
          { url: "https://example.com/over_limit.xml" }
        ]

        expect {
          result = described_class.call(user: free_user, outlines: outlines)
          expect(result.imported).to eq(2)
          expect(result.skipped).to eq(1)
          expect(result.errors.size).to eq(2)
        }.not_to raise_error
      end
    end
  end
end
