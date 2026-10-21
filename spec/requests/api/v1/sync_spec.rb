# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::V1::Sync", type: :request do
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
      unless name == "SCHEMA" || name == "TRANSACTION" || sql.match?(/\A(BEGIN|COMMIT|ROLLBACK|SAVEPOINT|RELEASE)\b/i)
        queries << sql
      end
    end
    block.call
    queries.size
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end

  def build_fetch_result(title: "Feed Title", site_url: "https://example.com", entries: [])
    Feeds::Fetcher::Result.new(
      success: true,
      error: nil,
      message: nil,
      status: 200,
      final_url: "https://example.com/feed.xml",
      etag: nil,
      last_modified: nil,
      feed: Feeds::Fetcher::ParsedFeed.new(title: title, site_url: site_url, entries: entries)
    )
  end

  def build_parsed_entry(guid:, url:, title:, author: "Alice", summary: "<p>Sum</p>", content: "<p>Body</p>", published_at: Time.utc(2026, 10, 1, 12, 0, 0))
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

  describe "GET /api/v1/sync" do
    it "returns 401 unauthorized without an Authorization token and with a revoked token" do
      get "/api/v1/sync"
      expect(response).to have_http_status(:unauthorized)
      expect(response.parsed_body["error"]["code"]).to eq("unauthorized")

      revoked_record, revoked_raw = ApiToken.issue!(user: user, name: "revoked-device")
      revoked_record.update!(revoked_at: Time.current)

      get "/api/v1/sync", headers: { "Authorization" => "Bearer #{revoked_raw}" }
      expect(response).to have_http_status(:unauthorized)
      expect(response.parsed_body["error"]["code"]).to eq("unauthorized")
    end

    it "returns exact top-level keys, String cursor, and EntrySummary entries with String ids and no changed_at, summary, or content on first sync" do
      feed = create(:feed, title: "Example Blog", site_url: "https://example.com")
      sub = create(:subscription, user: user, feed: feed)
      entry = create(
        :entry,
        feed: feed,
        title: "First Post",
        author: "Alice",
        url: "https://example.com/1",
        summary: "<p>Summary</p>",
        content: "<p>Content</p>",
        published_at: Time.utc(2026, 10, 2, 12, 0, 0)
      )

      get "/api/v1/sync", headers: headers
      expect(response).to have_http_status(:ok)

      body = response.parsed_body
      expect(body.keys).to match_array(%w[subscriptions entries cursor has_more])
      expect(body["cursor"]).to be_a(String)
      expect(body["has_more"]).to be(false)
      expect(body["entries"].size).to eq(1)

      entry_json = body["entries"].first
      expect(entry_json.keys).to match_array(%w[id subscription_id title author url published_at read starred])
      expect(entry_json["id"]).to be_a(String)
      expect(entry_json["subscription_id"]).to be_a(String)
      expect(entry_json).to eq(
        "id" => entry.id.to_s,
        "subscription_id" => sub.id.to_s,
        "title" => "First Post",
        "author" => "Alice",
        "url" => "https://example.com/1",
        "published_at" => "2026-10-02T12:00:00Z",
        "read" => false,
        "starred" => false
      )
      expect(entry_json).not_to have_key("changed_at")
      expect(entry_json).not_to have_key("summary")
      expect(entry_json).not_to have_key("content")
    end

    it "walks pages of 250 entries (100 / 100 / 50) by feeding each cursor back as since until has_more is false, then returns empty entries and the same cursor" do
      t_base = Time.utc(2026, 10, 1, 12, 0, 0)
      feed = create(:feed)
      create(:subscription, user: user, feed: feed, created_at: t_base, updated_at: t_base)

      expected_ids = (1..250).map do |i|
        t = t_base + i.seconds
        create(:entry, feed: feed, published_at: t, created_at: t, updated_at: t).id.to_s
      end

      get "/api/v1/sync", headers: headers
      expect(response).to have_http_status(:ok)
      p1 = response.parsed_body
      expect(p1["entries"].size).to eq(100)
      expect(p1["has_more"]).to be(true)

      get "/api/v1/sync", params: { since: p1["cursor"] }, headers: headers
      expect(response).to have_http_status(:ok)
      p2 = response.parsed_body
      expect(p2["entries"].size).to eq(100)
      expect(p2["has_more"]).to be(true)

      get "/api/v1/sync", params: { since: p2["cursor"] }, headers: headers
      expect(response).to have_http_status(:ok)
      p3 = response.parsed_body
      expect(p3["entries"].size).to eq(50)
      expect(p3["has_more"]).to be(false)

      collected_ids = (p1["entries"] + p2["entries"] + p3["entries"]).map { |e| e["id"] }
      expect(collected_ids).to eq(expected_ids)

      get "/api/v1/sync", params: { since: p3["cursor"] }, headers: headers
      expect(response).to have_http_status(:ok)
      p4 = response.parsed_body
      expect(p4["entries"]).to eq([])
      expect(p4["has_more"]).to be(false)
      expect(p4["cursor"]).to eq(p3["cursor"])
    end

    it "returns a subscriptions array identical to GET /api/v1/subscriptions (same keys, values, and order)" do
      feed_a = create(:feed, title: "Alpha", site_url: "https://alpha.example.com", last_fetched_at: Time.utc(2026, 10, 1, 9, 0, 0))
      feed_b = create(:feed, title: "Beta", site_url: "https://beta.example.com", status: "active")
      create(:subscription, user: user, feed: feed_a, custom_title: "Custom Alpha", created_at: Time.utc(2026, 10, 1, 10, 0, 0))
      create(:subscription, user: user, feed: feed_b, created_at: Time.utc(2026, 10, 1, 11, 0, 0))

      e1 = create(:entry, feed: feed_a)
      create(:entry, feed: feed_a)
      create(:entry, feed: feed_b)
      create(:entry_state, user: user, entry: e1, read_at: Time.current)

      get "/api/v1/subscriptions", headers: headers
      expect(response).to have_http_status(:ok)
      expected_subs = response.parsed_body["subscriptions"]

      get "/api/v1/sync", headers: headers
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["subscriptions"]).to eq(expected_subs)
    end

    it "integrates end-to-end with real write paths: PATCH state (read, starred, clear tombstone), POST mark_read, Feeds::Refresh, subscribe to existing feed, DELETE subscription, and re-subscribe" do
      t0 = Time.utc(2026, 10, 1, 10, 0, 0)
      feed_a = create(:feed, url: "https://example.com/a.xml", title: "Feed A")
      feed_b = create(:feed, url: "https://example.com/b.xml", title: "Feed B")

      # other_user already follows feed_b with pre-existing old entry
      create(:subscription, user: other_user, feed: feed_b, created_at: t0 - 1.day, updated_at: t0 - 1.day)
      old_entry_b = create(:entry, feed: feed_b, guid: "b-1", url: "https://example.com/b1", title: "Old B", published_at: t0 - 1.day, created_at: t0 - 1.day, updated_at: t0 - 1.day)

      sub_a = travel_to(t0, with_usec: true) { create(:subscription, user: user, feed: feed_a) }
      e_a1 = travel_to(t0 + 1.second, with_usec: true) { create(:entry, feed: feed_a, guid: "a-1", url: "https://example.com/a1", title: "A1", published_at: t0) }
      e_a2 = travel_to(t0 + 2.seconds, with_usec: true) { create(:entry, feed: feed_a, guid: "a-2", url: "https://example.com/a2", title: "A2", published_at: t0) }

      # Initial sync
      get "/api/v1/sync", headers: headers
      expect(response).to have_http_status(:ok)
      cursor = response.parsed_body["cursor"]
      expect(response.parsed_body["entries"].map { |e| e["id"] }).to eq([ e_a1.id.to_s, e_a2.id.to_s ])

      # (a) PATCH /entries/:id/state read: true
      travel_to(t0 + 10.seconds, with_usec: true) do
        patch "/api/v1/entries/#{e_a1.id}/state", params: { read: true }, headers: headers, as: :json
        expect(response).to have_http_status(:ok)
      end

      get "/api/v1/sync", params: { since: cursor }, headers: headers
      expect(response.parsed_body["entries"]).to match([
        a_hash_including("id" => e_a1.id.to_s, "read" => true, "starred" => false)
      ])
      cursor = response.parsed_body["cursor"]

      # (b) PATCH starred: true, then clear both (read: false, starred: false)
      travel_to(t0 + 20.seconds, with_usec: true) do
        patch "/api/v1/entries/#{e_a1.id}/state", params: { starred: true }, headers: headers, as: :json
      end
      travel_to(t0 + 21.seconds, with_usec: true) do
        patch "/api/v1/entries/#{e_a1.id}/state", params: { read: false, starred: false }, headers: headers, as: :json
      end

      get "/api/v1/sync", params: { since: cursor }, headers: headers
      expect(response.parsed_body["entries"]).to match([
        a_hash_including("id" => e_a1.id.to_s, "read" => false, "starred" => false)
      ])
      cursor = response.parsed_body["cursor"]

      # (c) POST /entries/mark_read
      travel_to(t0 + 30.seconds, with_usec: true) do
        post "/api/v1/entries/mark_read", params: { subscription_id: sub_a.id.to_s }, headers: headers, as: :json
        expect(response).to have_http_status(:ok)
        expect(response.parsed_body["marked"]).to eq(2)
      end

      get "/api/v1/sync", params: { since: cursor }, headers: headers
      expect(response.parsed_body["entries"].map { |e| [ e["id"], e["read"] ] }).to eq([
        [ e_a1.id.to_s, true ],
        [ e_a2.id.to_s, true ]
      ])
      cursor = response.parsed_body["cursor"]

      # (d) Feeds::Refresh updating e_a2 title
      travel_to(t0 + 40.seconds, with_usec: true) do
        parsed_a2 = build_parsed_entry(guid: "a-2", url: "https://example.com/a2", title: "A2 Updated", published_at: t0)
        Feeds::Refresh.call(feed_a, fetcher: ->(_u) { build_fetch_result(entries: [ parsed_a2 ]) })
      end

      get "/api/v1/sync", params: { since: cursor }, headers: headers
      expect(response.parsed_body["entries"]).to match([
        a_hash_including("id" => e_a2.id.to_s, "title" => "A2 Updated", "read" => true)
      ])
      cursor = response.parsed_body["cursor"]

      # (e) Subscribe to existing feed_b via POST /api/v1/subscriptions (no network fetch needed)
      sub_b1_id = nil
      travel_to(t0 + 50.seconds, with_usec: true) do
        post "/api/v1/subscriptions", params: { url: feed_b.url }, headers: headers, as: :json
        expect(response).to have_http_status(:created)
        sub_b1_id = response.parsed_body["subscription"]["id"]
      end

      get "/api/v1/sync", params: { since: cursor }, headers: headers
      expect(response.parsed_body["subscriptions"].map { |s| s["id"] }).to eq([ sub_a.id.to_s, sub_b1_id ])
      expect(response.parsed_body["entries"]).to match([
        a_hash_including("id" => old_entry_b.id.to_s, "subscription_id" => sub_b1_id, "title" => "Old B")
      ])
      cursor = response.parsed_body["cursor"]

      # (f) DELETE the subscription -> absent from snapshot and entries; re-subscribe -> returns with NEW subscription_id
      travel_to(t0 + 60.seconds, with_usec: true) do
        delete "/api/v1/subscriptions/#{sub_b1_id}", headers: headers
        expect(response).to have_http_status(:no_content)
      end

      get "/api/v1/sync", params: { since: cursor }, headers: headers
      expect(response.parsed_body["subscriptions"].map { |s| s["id"] }).to eq([ sub_a.id.to_s ])
      expect(response.parsed_body["entries"]).to eq([])
      cursor = response.parsed_body["cursor"]

      sub_b2_id = nil
      travel_to(t0 + 70.seconds, with_usec: true) do
        post "/api/v1/subscriptions", params: { url: feed_b.url }, headers: headers, as: :json
        expect(response).to have_http_status(:created)
        sub_b2_id = response.parsed_body["subscription"]["id"]
      end
      expect(sub_b2_id).not_to eq(sub_b1_id)

      get "/api/v1/sync", params: { since: cursor }, headers: headers
      expect(response.parsed_body["subscriptions"].map { |s| s["id"] }).to eq([ sub_a.id.to_s, sub_b2_id ])
      expect(response.parsed_body["entries"]).to match([
        a_hash_including("id" => old_entry_b.id.to_s, "subscription_id" => sub_b2_id)
      ])
    end

    it "converges a model-based client to the exact server truth from GET /entries and GET /subscriptions across a mixed operation sequence" do
      t = Time.utc(2026, 10, 1, 12, 0, 0)
      step = -> { t += 5.seconds }

      feed_1 = create(:feed, url: "https://example.com/f1.xml", title: "Feed 1")
      feed_2 = create(:feed, url: "https://example.com/f2.xml", title: "Feed 2")
      create(:subscription, user: other_user, feed: feed_1, created_at: t, updated_at: t)
      create(:subscription, user: other_user, feed: feed_2, created_at: t, updated_at: t)

      travel_to(step.call, with_usec: true) do
        create(:subscription, user: user, feed: feed_1)
        create(:subscription, user: user, feed: feed_2)
      end

      client_entries = {}
      client_subscriptions = []
      client_cursor = nil

      sync_client = lambda do
        loop do
          query = client_cursor ? { since: client_cursor } : {}
          get "/api/v1/sync", params: query, headers: headers
          expect(response).to have_http_status(:ok)
          body = response.parsed_body

          body["entries"].each do |entry|
            client_entries[entry["id"]] = entry.slice("id", "subscription_id", "title", "read", "starred")
          end

          client_subscriptions = body["subscriptions"]
          active_sub_ids = client_subscriptions.map { |s| s["id"] }.to_set
          client_entries.select! { |_id, e| active_sub_ids.include?(e["subscription_id"]) }

          client_cursor = body["cursor"]
          break unless body["has_more"]
        end
      end

      # 1. Refresh both feeds with new entries
      travel_to(step.call, with_usec: true) do
        Feeds::Refresh.call(feed_1, fetcher: ->(_u) {
          build_fetch_result(entries: [
            build_parsed_entry(guid: "f1-1", url: "https://example.com/f1/1", title: "F1 Post 1"),
            build_parsed_entry(guid: "f1-2", url: "https://example.com/f1/2", title: "F1 Post 2")
          ])
        })
        Feeds::Refresh.call(feed_2, fetcher: ->(_u) {
          build_fetch_result(entries: [
            build_parsed_entry(guid: "f2-1", url: "https://example.com/f2/1", title: "F2 Post 1"),
            build_parsed_entry(guid: "f2-2", url: "https://example.com/f2/2", title: "F2 Post 2")
          ])
        })
      end
      sync_client.call

      e_f1_1 = feed_1.entries.find_by!(guid: "f1-1")
      e_f1_2 = feed_1.entries.find_by!(guid: "f1-2")
      e_f2_1 = feed_2.entries.find_by!(guid: "f2-1")

      # 2. Entry update + read + star
      travel_to(step.call, with_usec: true) do
        Feeds::Refresh.call(feed_1, fetcher: ->(_u) {
          build_fetch_result(entries: [
            build_parsed_entry(guid: "f1-1", url: "https://example.com/f1/1", title: "F1 Post 1 Revised"),
            build_parsed_entry(guid: "f1-2", url: "https://example.com/f1/2", title: "F1 Post 2")
          ])
        })
        patch "/api/v1/entries/#{e_f1_1.id}/state", params: { read: true }, headers: headers, as: :json
        patch "/api/v1/entries/#{e_f1_2.id}/state", params: { starred: true }, headers: headers, as: :json
      end
      sync_client.call

      # 3. Bulk mark_read on feed_1 + unstar e_f1_2
      sub_1 = user.subscriptions.find_by!(feed_id: feed_1.id)
      travel_to(step.call, with_usec: true) do
        post "/api/v1/entries/mark_read", params: { subscription_id: sub_1.id.to_s }, headers: headers, as: :json
        patch "/api/v1/entries/#{e_f1_2.id}/state", params: { starred: false }, headers: headers, as: :json
      end
      sync_client.call

      # 4. Unsubscribe from feed_2
      sub_2 = user.subscriptions.find_by!(feed_id: feed_2.id)
      travel_to(step.call, with_usec: true) do
        delete "/api/v1/subscriptions/#{sub_2.id}", headers: headers
      end
      sync_client.call

      # 5. Re-subscribe to feed_2, star e_f2_1, and have other_user mutate their own state
      travel_to(step.call, with_usec: true) do
        post "/api/v1/subscriptions", params: { url: feed_2.url }, headers: headers, as: :json
        patch "/api/v1/entries/#{e_f2_1.id}/state", params: { starred: true }, headers: headers, as: :json
        patch "/api/v1/entries/#{e_f1_1.id}/state", params: { read: false, starred: true }, headers: other_headers, as: :json
      end
      sync_client.call

      # Compare client state with server truth from GET /entries and GET /subscriptions
      server_entries = {}
      list_cursor = nil
      loop do
        params = list_cursor ? { cursor: list_cursor } : {}
        get "/api/v1/entries", params: params, headers: headers
        expect(response).to have_http_status(:ok)
        page = response.parsed_body
        page["entries"].each do |e|
          server_entries[e["id"]] = e.slice("id", "subscription_id", "title", "read", "starred")
        end
        list_cursor = page["next_cursor"]
        break unless list_cursor
      end

      get "/api/v1/subscriptions", headers: headers
      server_subscriptions = response.parsed_body["subscriptions"]

      expect(client_entries).to eq(server_entries)
      expect(client_subscriptions).to eq(server_subscriptions)
    end

    it "isolates user A from user B's states, subscriptions, and entries" do
      # Ensure other_user is created first so User.first != current_user
      other = other_user
      user_a = user

      feed_shared = create(:feed)
      feed_b_only = create(:feed)

      sub_a = create(:subscription, user: user_a, feed: feed_shared)
      sub_b1 = create(:subscription, user: other, feed: feed_shared)
      sub_b2 = create(:subscription, user: other, feed: feed_b_only)

      e_shared = create(:entry, feed: feed_shared)
      e_b_only = create(:entry, feed: feed_b_only)

      create(:entry_state, user: other, entry: e_shared, read_at: Time.current, starred_at: Time.current)
      create(:entry_state, user: other, entry: e_b_only, read_at: Time.current)

      get "/api/v1/sync", headers: headers
      expect(response).to have_http_status(:ok)

      body = response.parsed_body
      expect(body["subscriptions"].size).to eq(1)
      expect(body["subscriptions"].map { |s| s["id"] }).to eq([ sub_a.id.to_s ])
      expect(body["subscriptions"].map { |s| s["id"] }).not_to include(sub_b1.id.to_s, sub_b2.id.to_s)

      expect(body["entries"].size).to eq(1)
      expect(body["entries"].map { |e| e["id"] }).to eq([ e_shared.id.to_s ])
      expect(body["entries"].first).to include("read" => false, "starred" => false)
    end

    it "returns 400 bad_request with details.param='since' for invalid since query parameters, and ignores since in the JSON body" do
      feed = create(:feed)
      create(:subscription, user: user, feed: feed)
      entry = create(:entry, feed: feed)

      b64 = ->(str) { Base64.urlsafe_encode64(str, padding: false) }
      expected_error = {
        "error" => {
          "code" => "bad_request",
          "message" => "Invalid since parameter",
          "details" => { "param" => "since" }
        }
      }

      invalid_query_strings = [
        "since=",
        "since=not-valid-base64!!!",
        "since=#{b64.call('not-json')}",
        "since=#{b64.call('{"changed_at":"2026-10-21T12:00:00.000000Z","id":1,"tampered":true}')}",
        "since=#{b64.call('{"changed_at":"2026-10-21T12:00:00.000000Z","id":"1"}')}",
        "since=#{b64.call('{"changed_at":"2026-10-21T12:00:00.000000Z","id":1.5}')}",
        "since=#{'a' * 257}",
        "since[]=x",
        "since[a]=b"
      ]

      invalid_query_strings.each do |qs|
        get "/api/v1/sync?#{qs}", headers: headers
        expect(response).to have_http_status(:bad_request), "Expected 400 for query #{qs.inspect}, got #{response.status}"
        expect(response.parsed_body).to eq(expected_error)
      end

      # `since` present only in the JSON body must be ignored => 200 first sync
      raw_body = { since: "garbage" }.to_json
      get "/api/v1/sync",
          headers: headers.merge(
            "CONTENT_TYPE" => "application/json",
            "CONTENT_LENGTH" => raw_body.bytesize.to_s,
            "rack.input" => StringIO.new(raw_body)
          )
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["entries"].map { |e| e["id"] }).to eq([ entry.id.to_s ])
    end

    it "returns 200 with empty entries and the same cursor for a syntactically valid cursor far in the future" do
      feed = create(:feed)
      create(:subscription, user: user, feed: feed)
      create(:entry, feed: feed)

      future_cursor = Entries::SyncCursor.encode(changed_at: Time.utc(2099, 1, 1, 0, 0, 0, 123_456), id: 999)

      get "/api/v1/sync", params: { since: future_cursor }, headers: headers
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["entries"]).to eq([])
      expect(response.parsed_body["has_more"]).to be(false)
      expect(response.parsed_body["cursor"]).to eq(future_cursor)
    end

    it "executes a constant number of SQL queries for 5 vs 100 entries and 1 vs 5 subscriptions" do
      feed1 = create(:feed)
      create(:subscription, user: user, feed: feed1)
      5.times { create(:entry, feed: feed1) }

      # Warm up auth token last_used_at throttle
      get "/api/v1/sync", headers: headers
      expect(response).to have_http_status(:ok)

      queries_small = count_queries do
        get "/api/v1/sync", headers: headers
      end
      expect(response).to have_http_status(:ok)

      4.times do
        f = create(:feed)
        create(:subscription, user: user, feed: f)
        25.times { create(:entry, feed: f) }
      end

      queries_large = count_queries do
        get "/api/v1/sync", headers: headers
      end
      expect(response).to have_http_status(:ok)

      expect(queries_large).to eq(queries_small)
    end
  end
end
