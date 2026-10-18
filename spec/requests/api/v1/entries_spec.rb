# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::V1::Entries", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  let(:user) { create(:user, email: "alice@example.com", plan: "pro") }
  let(:token) { ApiToken.issue!(user: user, name: "laptop")[1] }
  let(:headers) { { "Authorization" => "Bearer #{token}" } }

  let(:other_user) { create(:user, email: "bob@example.com", plan: "pro") }
  let(:other_token) { ApiToken.issue!(user: other_user, name: "bob-laptop")[1] }
  let(:other_headers) { { "Authorization" => "Bearer #{other_token}" } }

  def count_queries(&block)
    queries = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |_name, _start, _finish, _id, payload|
      sql = payload[:sql].to_s.strip
      name = payload[:name].to_s
      unless name == "SCHEMA" || name == "TRANSACTION" || sql =~ /\A(BEGIN|COMMIT|ROLLBACK|SAVEPOINT|RELEASE)\b/i
        queries << sql
      end
    end
    block.call
    queries.size
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end

  describe "Authentication (h)" do
    it "returns 401 unauthorized without an Authorization token" do
      get "/api/v1/entries"

      expect(response).to have_http_status(:unauthorized)
      expect(response.parsed_body["error"]["code"]).to eq("unauthorized")
    end
  end

  describe "EntrySummary shape and cross-user isolation (a)" do
    it "returns EntrySummary fields without content, includes entries older than subscription, and isolates users and deleted subscriptions" do
      feed_a = create(:feed)
      feed_only_other = create(:feed)

      old_entry = create(
        :entry,
        feed: feed_a,
        title: "Old Post",
        author: "Alice Author",
        url: "https://example.com/old",
        summary: "<p>Sanitized summary</p>",
        content: "<p>Full secret content that must not appear in list</p>",
        published_at: Time.utc(2026, 10, 1, 12, 0, 0)
      )
      other_entry = create(
        :entry,
        feed: feed_only_other,
        title: "Bob Only Post",
        published_at: Time.utc(2026, 10, 2, 12, 0, 0)
      )

      sub_a = travel_to(Time.utc(2026, 10, 10, 12, 0, 0)) do
        create(:subscription, user: user, feed: feed_a)
      end
      create(:subscription, user: other_user, feed: feed_only_other)
      create(:subscription, user: other_user, feed: feed_a)

      # Other user marks old_entry read & starred; must not affect user
      create(:entry_state, user: other_user, entry: old_entry, read_at: Time.current, starred_at: Time.current)

      get "/api/v1/entries", headers: headers
      expect(response).to have_http_status(:ok)

      body = response.parsed_body
      expect(body["next_cursor"]).to be_nil
      expect(body["entries"].size).to eq(1)

      entry_json = body["entries"].first
      expect(entry_json).to eq(
        "id" => old_entry.id.to_s,
        "subscription_id" => sub_a.id.to_s,
        "title" => "Old Post",
        "author" => "Alice Author",
        "url" => "https://example.com/old",
        "summary" => "<p>Sanitized summary</p>",
        "published_at" => "2026-10-01T12:00:00Z",
        "read" => false,
        "starred" => false
      )
      expect(entry_json).not_to have_key("content")
      expect(body["entries"].map { |e| e["id"] }).not_to include(other_entry.id.to_s)

      # Deleting the subscription hides its entries
      sub_a.destroy!

      get "/api/v1/entries", headers: headers
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["entries"]).to eq([])
    end
  end

  describe "Keyset pagination (b)" do
    it "walks through all pages without duplicates or gaps, handling published_at ties and newly inserted entries between pages" do
      feed = create(:feed)
      create(:subscription, user: user, feed: feed)

      tied_time = Time.utc(2026, 10, 10, 15, 30, 45, 123456)
      older_time = Time.utc(2026, 10, 9, 10, 0, 0)
      newer_time = Time.utc(2026, 10, 11, 10, 0, 0)

      e_old1 = create(:entry, feed: feed, published_at: older_time - 1.hour)
      e_old2 = create(:entry, feed: feed, published_at: older_time)
      # 4 entries with the exact same published_at across page boundaries
      e_tie1 = create(:entry, feed: feed, published_at: tied_time)
      e_tie2 = create(:entry, feed: feed, published_at: tied_time)
      e_tie3 = create(:entry, feed: feed, published_at: tied_time)
      e_tie4 = create(:entry, feed: feed, published_at: tied_time)
      e_new = create(:entry, feed: feed, published_at: newer_time)

      expected_ids = [ e_new, e_tie4, e_tie3, e_tie2, e_tie1, e_old2, e_old1 ].map { |e| e.id.to_s }

      collected_ids = []
      cursor = nil
      page_count = 0

      loop do
        params = { limit: 2 }
        params[:cursor] = cursor if cursor

        get "/api/v1/entries", params: params, headers: headers
        expect(response).to have_http_status(:ok)

        body = response.parsed_body
        page_ids = body["entries"].map { |e| e["id"] }
        expect(page_ids).not_to be_empty
        collected_ids.concat(page_ids)
        page_count += 1

        # Insert a brand-new entry at the top after fetching the first page
        if page_count == 1
          create(:entry, feed: feed, published_at: newer_time + 1.hour)
        end

        cursor = body["next_cursor"]
        break if cursor.nil? || page_count >= 10
      end

      expect(collected_ids).to eq(expected_ids)
      expect(page_count).to eq(4)
    end
  end

  describe "Cursor validation (c)" do
    it "returns 400 bad_request with details.param='cursor' for malformed, tampered, wrongly typed, or empty cursors" do
      valid_json = JSON.generate(published_at: "2026-10-10T12:00:00.000000Z", id: 42)
      valid_b64 = Base64.urlsafe_encode64(valid_json, padding: false)
      # Flip the last character to tamper with base64 padding bits or JSON
      tampered_b64 = valid_b64[0...-1] + (valid_b64[-1] == "A" ? "B" : "A")

      invalid_cursors = [
        "",
        "!!!not-base64!!!",
        tampered_b64,
        Base64.urlsafe_encode64("not-json", padding: false),
        Base64.urlsafe_encode64("[]", padding: false),
        Base64.urlsafe_encode64(JSON.generate(published_at: "2026-10-10T12:00:00Z"), padding: false),
        Base64.urlsafe_encode64(JSON.generate(published_at: "2026-10-10T12:00:00Z", id: 1, extra: true), padding: false),
        Base64.urlsafe_encode64(JSON.generate(published_at: "2026-10-10T12:00:00Z", id: "1"), padding: false),
        Base64.urlsafe_encode64(JSON.generate(published_at: "2026-10-10T12:00:00Z", id: 0), padding: false),
        Base64.urlsafe_encode64(JSON.generate(published_at: "2026-10-10T12:00:00Z", id: -5), padding: false),
        Base64.urlsafe_encode64(JSON.generate(published_at: 12345, id: 1), padding: false),
        Base64.urlsafe_encode64(JSON.generate(published_at: "not-a-timestamp", id: 1), padding: false)
      ]

      invalid_cursors.each do |bad_cursor|
        get "/api/v1/entries", params: { cursor: bad_cursor }, headers: headers
        expect(response).to have_http_status(:bad_request), "Expected 400 for cursor=#{bad_cursor.inspect}, got #{response.status}"
        error = response.parsed_body["error"]
        expect(error["code"]).to eq("bad_request")
        expect(error["details"]).to eq("param" => "cursor")
      end
    end
  end

  describe "Filters and combinations (d)" do
    let(:feed1) { create(:feed) }
    let(:feed2) { create(:feed) }
    let!(:sub1) { create(:subscription, user: user, feed: feed1) }
    let!(:sub2) { create(:subscription, user: user, feed: feed2) }

    # e1: no entry_state row (unread, unstarred)
    let!(:e1) { create(:entry, feed: feed1, published_at: 1.hour.ago) }
    # e2: entry_state with read_at nil, starred_at nil (unread, unstarred)
    let!(:e2) { create(:entry, feed: feed1, published_at: 2.hours.ago) }
    # e3: read and unstarred
    let!(:e3) { create(:entry, feed: feed1, published_at: 3.hours.ago) }
    # e4: unread and starred
    let!(:e4) { create(:entry, feed: feed1, published_at: 4.hours.ago) }
    # e5: read and starred (in feed2)
    let!(:e5) { create(:entry, feed: feed2, published_at: 5.hours.ago) }

    before do
      create(:entry_state, user: user, entry: e2, read_at: nil, starred_at: nil)
      create(:entry_state, user: user, entry: e3, read_at: Time.current, starred_at: nil)
      create(:entry_state, user: user, entry: e4, read_at: nil, starred_at: Time.current)
      create(:entry_state, user: user, entry: e5, read_at: Time.current, starred_at: Time.current)
    end

    it "filters by unread=true and unread=false, treating missing state row as unread" do
      get "/api/v1/entries", params: { unread: "true" }, headers: headers
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["entries"].map { |e| e["id"] }).to eq([ e1.id.to_s, e2.id.to_s, e4.id.to_s ])

      get "/api/v1/entries", params: { unread: "false" }, headers: headers
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["entries"].map { |e| e["id"] }).to eq([ e3.id.to_s, e5.id.to_s ])
    end

    it "filters by starred=true and starred=false, treating missing state row as unstarred" do
      get "/api/v1/entries", params: { starred: "true" }, headers: headers
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["entries"].map { |e| e["id"] }).to eq([ e4.id.to_s, e5.id.to_s ])

      get "/api/v1/entries", params: { starred: "false" }, headers: headers
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["entries"].map { |e| e["id"] }).to eq([ e1.id.to_s, e2.id.to_s, e3.id.to_s ])
    end

    it "combines subscription_id, unread, and starred filters and reflects read/starred booleans accurately" do
      get "/api/v1/entries", params: { unread: "true", starred: "true" }, headers: headers
      expect(response).to have_http_status(:ok)
      entries = response.parsed_body["entries"]
      expect(entries.map { |e| e["id"] }).to eq([ e4.id.to_s ])
      expect(entries.first["read"]).to be(false)
      expect(entries.first["starred"]).to be(true)

      get "/api/v1/entries", params: { subscription_id: sub1.id, unread: "false", starred: "false" }, headers: headers
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["entries"].map { |e| e["id"] }).to eq([ e3.id.to_s ])

      get "/api/v1/entries", params: { subscription_id: sub2.id, unread: "false", starred: "true" }, headers: headers
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["entries"].map { |e| e["id"] }).to eq([ e5.id.to_s ])
    end

    it "returns 400 bad_request when unread or starred has an invalid value" do
      %w[1 0 yes no invalid].concat([ "" ]).each do |bad_val|
        get "/api/v1/entries", params: { unread: bad_val }, headers: headers
        expect(response).to have_http_status(:bad_request)
        expect(response.parsed_body["error"]["details"]).to eq("param" => "unread")

        get "/api/v1/entries", params: { starred: bad_val }, headers: headers
        expect(response).to have_http_status(:bad_request)
        expect(response.parsed_body["error"]["details"]).to eq("param" => "starred")
      end
    end
  end

  describe "Limit rules (e)" do
    it "defaults to 50, clamps values above 100 to 100, and returns 400 for 0, -1, or non-integers" do
      feed = create(:feed)
      create(:subscription, user: user, feed: feed)

      now = Time.current
      105.times do |i|
        create(:entry, feed: feed, guid: "g-#{i}", url: "https://example.com/#{i}", published_at: now - i.minutes)
      end

      # Default limit = 50
      get "/api/v1/entries", headers: headers
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["entries"].size).to eq(50)
      expect(response.parsed_body["next_cursor"]).to be_present

      # Clamped to 100
      get "/api/v1/entries", params: { limit: 250 }, headers: headers
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["entries"].size).to eq(100)
      expect(response.parsed_body["next_cursor"]).to be_present

      # Invalid limits -> 400 with details.param = "limit"
      [ 0, -1, "abc", "", "10abc", "1.5" ].each do |bad_limit|
        get "/api/v1/entries", params: { limit: bad_limit }, headers: headers
        expect(response).to have_http_status(:bad_request), "Expected 400 for limit=#{bad_limit.inspect}"
        expect(response.parsed_body["error"]["code"]).to eq("bad_request")
        expect(response.parsed_body["error"]["details"]).to eq("param" => "limit")
      end
    end
  end

  describe "Unknown and foreign subscription_id (f)" do
    it "returns 404 not_found with identical bodies for unknown and foreign subscription_id" do
      foreign_feed = create(:feed)
      foreign_sub = create(:subscription, user: other_user, feed: foreign_feed)

      get "/api/v1/entries", params: { subscription_id: 999_999 }, headers: headers
      expect(response).to have_http_status(:not_found)
      unknown_body = response.body

      get "/api/v1/entries", params: { subscription_id: foreign_sub.id }, headers: headers
      expect(response).to have_http_status(:not_found)
      foreign_body = response.body

      expect(foreign_body).to eq(unknown_body)
      expect(response.parsed_body["error"]["code"]).to eq("not_found")
    end
  end

  describe "Constant SQL query count (g)" do
    it "executes a constant number of SQL queries for 5 vs 100 entries and 1 vs 5 subscriptions" do
      feed_single = create(:feed)
      create(:subscription, user: user, feed: feed_single)
      5.times { |i| create(:entry, feed: feed_single, guid: "s-#{i}", published_at: i.minutes.ago) }

      # Warm up auth token last_used_at throttle so token update query does not skew comparison
      get "/api/v1/entries", headers: headers
      expect(response).to have_http_status(:ok)

      queries_1_sub_5_entries = count_queries do
        get "/api/v1/entries", params: { limit: 100 }, headers: headers
      end
      expect(response.parsed_body["entries"].size).to eq(5)

      4.times do |f_idx|
        f = create(:feed)
        create(:subscription, user: user, feed: f)
        25.times do |e_idx|
          entry = create(:entry, feed: f, guid: "m-#{f_idx}-#{e_idx}", published_at: (f_idx * 30 + e_idx).minutes.ago)
          create(:entry_state, user: user, entry: entry, read_at: Time.current) if e_idx.even?
        end
      end

      queries_5_subs_100_entries = count_queries do
        get "/api/v1/entries", params: { limit: 100 }, headers: headers
      end
      expect(response.parsed_body["entries"].size).to eq(100)

      expect(queries_5_subs_100_entries).to eq(queries_1_sub_5_entries)
    end
  end
end
