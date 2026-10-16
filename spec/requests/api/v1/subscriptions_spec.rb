# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::V1::Subscriptions", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  let(:user) { create(:user, email: "alice@example.com", plan: "free") }
  let(:token) { ApiToken.issue!(user: user, name: "laptop")[1] }
  let(:headers) { { "Authorization" => "Bearer #{token}" } }

  let(:pro_user) { create(:user, email: "pro@example.com", plan: "pro") }
  let(:pro_token) { ApiToken.issue!(user: pro_user, name: "laptop-pro")[1] }
  let(:pro_headers) { { "Authorization" => "Bearer #{pro_token}" } }

  def count_queries(&block)
    queries = []
    subscription = ActiveSupport::Notifications.subscribe("sql.active_record") do |_name, _start, _finish, _id, payload|
      sql = payload[:sql].to_s.strip
      name = payload[:name].to_s
      unless name == "SCHEMA" || name == "TRANSACTION" || sql =~ /\A(BEGIN|COMMIT|ROLLBACK|SAVEPOINT|RELEASE)\b/i
        queries << sql
      end
    end
    block.call
    queries.size
  ensure
    ActiveSupport::Notifications.unsubscribe(subscription)
  end

  def build_fetch_result(
    success: true,
    error: nil,
    message: nil,
    title: "Parsed Feed Title",
    site_url: "https://example.com",
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
      final_url: "https://example.com/feed.xml",
      etag: '"etag-123"',
      last_modified: "Wed, 21 Oct 2026 07:28:00 GMT",
      feed: success ? feed_data : nil
    )
  end

  def build_entry(guid: "g-1", url: "https://example.com/1", title: "Post 1")
    Feeds::Fetcher::ParsedEntry.new(
      guid: guid,
      url: url,
      title: title,
      author: "Alice",
      summary: "Summary",
      content: "<p>Content</p>",
      published_at: 1.day.ago
    )
  end

  describe "Authentication" do
    it "returns 401 without an Authorization token" do
      get "/api/v1/subscriptions"
      expect(response).to have_http_status(:unauthorized)
      expect(response.parsed_body["error"]["code"]).to eq("unauthorized")

      post "/api/v1/subscriptions", params: { url: "https://example.com/feed.xml" }, as: :json
      expect(response).to have_http_status(:unauthorized)
      expect(response.parsed_body["error"]["code"]).to eq("unauthorized")

      delete "/api/v1/subscriptions/1"
      expect(response).to have_http_status(:unauthorized)
      expect(response.parsed_body["error"]["code"]).to eq("unauthorized")
    end
  end

  describe "POST /api/v1/subscriptions" do
    describe "happy paths and existing feeds" do
      it "subscribes to a new feed end to end (201, payload, feed and entries created, fetched once)" do
        stub_const("Feeds::Fetcher::DEFAULT_RESOLVER", ->(_host) { [ IPAddr.new("93.184.216.34") ] })

        fixture_content = File.read(Rails.root.join("spec/fixtures/files/feeds/rss20.xml"))
        stub_feed_request = stub_request(:get, "https://example.com/feed.xml")
          .to_return(
            status: 200,
            headers: { "Content-Type" => "application/rss+xml" },
            body: fixture_content
          )

        expect {
          post "/api/v1/subscriptions",
               params: { url: "https://example.com/feed.xml" },
               headers: headers,
               as: :json
        }.to change(Subscription, :count).by(1)
         .and change(Feed, :count).by(1)
         .and change(Entry, :count).by(2)

        expect(response).to have_http_status(:created)
        expect(stub_feed_request).to have_been_requested.once

        json = response.parsed_body
        subscription_json = json["subscription"]
        expect(subscription_json["id"]).to be_a(String)
        expect(subscription_json["title"]).to eq("Cerrynt RSS Feed")
        expect(subscription_json["custom_title"]).to be_nil
        expect(subscription_json["url"]).to eq("https://example.com/feed.xml")
        expect(subscription_json["site_url"]).to eq("https://example.com/rss")
        expect(subscription_json["unread_count"]).to eq(2)
        expect(subscription_json["status"]).to eq("active")
        expect(subscription_json["last_fetched_at"]).to be_present
      end

      it "fetches outside of any database transaction" do
        baseline_transactions = ActiveRecord::Base.connection.open_transactions
        target_url = "https://example.com/no_tx_feed.xml"

        allow(Feeds::Fetcher).to receive(:call).with(target_url, deadline: 5) do
          expect(ActiveRecord::Base.connection.open_transactions).to eq(baseline_transactions)
          build_fetch_result(title: "No Tx Feed")
        end

        post "/api/v1/subscriptions", params: { url: target_url }, headers: headers, as: :json
        expect(response).to have_http_status(:created)
      end

      it "subscribes to an existing feed of another user without fetching (201, NO fetch, no new Feed row)" do
        other_user = create(:user)
        existing_feed = create(:feed, url: "https://example.com/shared_other.xml", title: "Shared Feed")
        create(:subscription, user: other_user, feed: existing_feed)

        expect(Feeds::Fetcher).not_to receive(:call)

        expect {
          post "/api/v1/subscriptions",
               params: { url: "https://example.com/shared_other.xml" },
               headers: headers,
               as: :json
        }.to change(user.subscriptions, :count).by(1)
         .and not_change(Feed, :count)

        expect(Feed.where(url: "https://example.com/shared_other.xml").count).to eq(1)
        expect(response).to have_http_status(:created)
        expect(response.parsed_body.dig("subscription", "title")).to eq("Shared Feed")
        expect(response.parsed_body.dig("subscription", "url")).to eq("https://example.com/shared_other.xml")
      end

      it "returns 200 with existing subscription when already subscribed, even at plan limit" do
        feed1 = create(:feed, url: "https://example.com/limit1.xml")
        feed2 = create(:feed, url: "https://example.com/limit2.xml")
        sub1 = create(:subscription, user: user, feed: feed1)
        create(:subscription, user: user, feed: feed2)
        expect(user.subscriptions.count).to eq(2) # at free limit

        expect(Feeds::Fetcher).not_to receive(:call)

        expect {
          post "/api/v1/subscriptions",
               params: { url: "https://example.com/limit1.xml" },
               headers: headers,
               as: :json
        }.to not_change(Subscription, :count)
         .and not_change(Feed, :count)

        expect(response).to have_http_status(:ok)
        expect(response.parsed_body.dig("subscription", "id")).to eq(sub1.id.to_s)
        expect(user.subscriptions.count).to eq(2)
      end

      it "resolves URL variants such as HTTP scheme case, fragments, and root slash to the same feed" do
        existing_feed = create(:feed, url: "http://example.com/feed.xml", title: "Case Feed")

        expect(Feeds::Fetcher).not_to receive(:call)

        post "/api/v1/subscriptions",
             params: { url: "HTTP://Example.COM/feed.xml#frag" },
             headers: headers,
             as: :json

        expect(response).to have_http_status(:created)
        expect(response.parsed_body.dig("subscription", "url")).to eq("http://example.com/feed.xml")
        expect(user.subscriptions.last.feed_id).to eq(existing_feed.id)
      end
    end

    describe "plan limits" do
      it "rejects free user at 2 feeds with 403 feed_limit_reached details and NO fetch" do
        feed1 = create(:feed, url: "https://example.com/pl1.xml")
        feed2 = create(:feed, url: "https://example.com/pl2.xml")
        create(:subscription, user: user, feed: feed1)
        create(:subscription, user: user, feed: feed2)

        expect(Feeds::Fetcher).not_to receive(:call)

        expect {
          post "/api/v1/subscriptions",
               params: { url: "https://example.com/new_limit_feed.xml" },
               headers: headers,
               as: :json
        }.to not_change(Subscription, :count)
         .and not_change(Feed, :count)

        expect(Feed.find_by(url: "https://example.com/new_limit_feed.xml")).to be_nil
        expect(response).to have_http_status(:forbidden)
        expect(response.parsed_body).to eq({
          "error" => {
            "code" => "feed_limit_reached",
            "message" => "Free plan allows 2 feeds.",
            "details" => { "limit" => 2, "plan" => "free" }
          }
        })
      end

      it "rejects subscribing to an existing feed of another user when at plan limit with 403 and NO fetch" do
        feed1 = create(:feed, url: "https://example.com/exist_limit1.xml")
        feed2 = create(:feed, url: "https://example.com/exist_limit2.xml")
        create(:subscription, user: user, feed: feed1)
        create(:subscription, user: user, feed: feed2)
        expect(user.subscriptions.count).to eq(2)

        other_user = create(:user)
        shared_feed = create(:feed, url: "https://example.com/shared_limit.xml", title: "Shared Feed")
        create(:subscription, user: other_user, feed: shared_feed)

        expect(Feeds::Fetcher).not_to receive(:call)

        expect {
          post "/api/v1/subscriptions", params: { url: shared_feed.url }, headers: headers, as: :json
        }.to not_change(Subscription, :count)
         .and not_change(Feed, :count)

        expect(response).to have_http_status(:forbidden)
        expect(response.parsed_body.dig("error", "code")).to eq("feed_limit_reached")
        expect(response.parsed_body.dig("error", "details")).to eq({ "limit" => 2, "plan" => "free" })
      end

      it "allows a pro user to exceed 2 subscriptions" do
        feed1 = create(:feed, url: "https://example.com/pro1.xml")
        feed2 = create(:feed, url: "https://example.com/pro2.xml")
        create(:subscription, user: pro_user, feed: feed1)
        create(:subscription, user: pro_user, feed: feed2)

        allow(Feeds::Fetcher).to receive(:call)
          .with("https://example.com/pro3.xml", deadline: 5)
          .and_return(build_fetch_result(title: "Feed 3"))

        expect {
          post "/api/v1/subscriptions",
               params: { url: "https://example.com/pro3.xml" },
               headers: pro_headers,
               as: :json
        }.to change(pro_user.subscriptions, :count).by(1)

        expect(response).to have_http_status(:created)
      end
    end

    describe "input validation and fetch failure mappings" do
      it "returns 422 invalid_feed_url for blank, missing, and non-string URLs" do
        [ "", "   ", nil, { "not" => "string" }, [ "not", "string" ], 123 ].each do |invalid_url|
          expect(Feeds::Fetcher).not_to receive(:call)

          expect {
            post "/api/v1/subscriptions",
                 params: { url: invalid_url },
                 headers: headers,
                 as: :json
          }.to not_change(Feed, :count)
           .and not_change(Subscription, :count)

          expect(response).to have_http_status(:unprocessable_content)
          expect(response.parsed_body).to eq({
            "error" => {
              "code" => "invalid_feed_url",
              "message" => "Invalid feed URL",
              "details" => {}
            }
          })
        end
      end

      it "returns 422 invalid_feed_url and never calls fetcher when url is 2049 characters" do
        too_long_url = "https://example.com/" + ("a" * 2029)
        expect(too_long_url.length).to eq(2049)

        expect(Feeds::Fetcher).not_to receive(:call)

        expect {
          post "/api/v1/subscriptions", params: { url: too_long_url }, headers: headers, as: :json
        }.to not_change(Feed, :count)
         .and not_change(Subscription, :count)

        expect(response).to have_http_status(:unprocessable_content)
        expect(response.parsed_body.dig("error", "code")).to eq("invalid_feed_url")
      end

      it "returns 422 invalid_feed_url for ftp: and javascript: schemes" do
        [ "ftp://example.com/feed.xml", "javascript:alert(1)" ].each do |bad_url|
          expect {
            post "/api/v1/subscriptions",
                 params: { url: bad_url },
                 headers: headers,
                 as: :json
          }.to not_change(Feed, :count)
           .and not_change(Subscription, :count)

          expect(response).to have_http_status(:unprocessable_content)
          expect(response.parsed_body["error"]["code"]).to eq("invalid_feed_url")
          expect(response.parsed_body["error"]["details"]).to eq({})
        end
      end

      it "returns 422 feed_unreachable for blocked address without leaking IP" do
        expect {
          post "/api/v1/subscriptions",
               params: { url: "http://127.0.0.1/feed.xml" },
               headers: headers,
               as: :json
        }.to not_change(Feed, :count)
         .and not_change(Subscription, :count)

        expect(response).to have_http_status(:unprocessable_content)
        expect(response.parsed_body["error"]["code"]).to eq("feed_unreachable")
        expect(response.body).not_to include("127.0.0.1")
      end

      it "produces identical bodies for :blocked_address and :unreachable and leaks no IPs" do
        allow(Feeds::Fetcher).to receive(:call).with("https://example.com/blocked.xml", deadline: 5)
          .and_return(Feeds::Fetcher::Result.new(
            success: false, error: :blocked_address, message: "Blocked address: 10.0.0.1",
            status: nil, final_url: "https://example.com/blocked.xml", etag: nil, last_modified: nil, feed: nil
          ))

        allow(Feeds::Fetcher).to receive(:call).with("https://example.com/unreachable.xml", deadline: 5)
          .and_return(Feeds::Fetcher::Result.new(
            success: false, error: :unreachable, message: "Host unreachable: 10.0.0.1",
            status: nil, final_url: "https://example.com/unreachable.xml", etag: nil, last_modified: nil, feed: nil
          ))

        post "/api/v1/subscriptions", params: { url: "https://example.com/blocked.xml" }, headers: headers, as: :json
        blocked_body = response.parsed_body

        post "/api/v1/subscriptions", params: { url: "https://example.com/unreachable.xml" }, headers: headers, as: :json
        unreachable_body = response.parsed_body

        expect(blocked_body).to eq(unreachable_body)
        expect(blocked_body).to eq({
          "error" => {
            "code" => "feed_unreachable",
            "message" => "Feed is unreachable",
            "details" => {}
          }
        })
        expect(response.body).not_to include("10.0.0.1")
      end

      it "maps every fetcher error code correctly and creates neither feed nor subscription" do
        test_cases = {
          not_a_feed: [ :unprocessable_content, "invalid_feed_url" ],
          invalid_url: [ :unprocessable_content, "invalid_feed_url" ],
          blocked_address: [ :unprocessable_content, "feed_unreachable" ],
          unreachable: [ :unprocessable_content, "feed_unreachable" ],
          timeout: [ :unprocessable_content, "feed_unreachable" ],
          too_large: [ :unprocessable_content, "feed_unreachable" ],
          too_many_redirects: [ :unprocessable_content, "feed_unreachable" ],
          http_error: [ :unprocessable_content, "feed_unreachable" ]
        }

        test_cases.each do |error_symbol, (expected_status, expected_code)|
          target_url = "https://example.com/err_#{error_symbol}.xml"
          allow(Feeds::Fetcher).to receive(:call).with(target_url, deadline: 5)
            .and_return(Feeds::Fetcher::Result.new(
              success: false, error: error_symbol, message: "Internal detail with IP 192.168.1.1",
              status: 500, final_url: target_url, etag: nil, last_modified: nil, feed: nil
            ))

          expect {
            post "/api/v1/subscriptions", params: { url: target_url }, headers: headers, as: :json
          }.to not_change(Feed, :count)
           .and not_change(Subscription, :count)

          expect(response).to have_http_status(expected_status)
          expect(response.parsed_body["error"]["code"]).to eq(expected_code)
          expect(response.parsed_body["error"]["details"]).to eq({})
          expect(response.body).not_to include("192.168.1.1")
        end
      end
    end

    describe "concurrency and race conditions" do
      it "handles race 1: another subscription for same user created during fetch, in-lock recheck returns 403 and no Feed row exists" do
        feed1 = create(:feed, url: "https://example.com/existing1_r1.xml")
        create(:subscription, user: user, feed: feed1)
        expect(user.subscriptions.count).to eq(1)

        target_url = "https://example.com/race1.xml"
        allow(Feeds::Fetcher).to receive(:call).with(target_url, deadline: 5) do
          concurrent_feed = create(:feed, url: "https://example.com/concurrent.xml")
          create(:subscription, user: user, feed: concurrent_feed)

          build_fetch_result(title: "Race 1 Feed")
        end

        expect {
          post "/api/v1/subscriptions", params: { url: target_url }, headers: headers, as: :json
        }.to not_change { Feed.where(url: target_url).count }

        expect(response).to have_http_status(:forbidden)
        expect(response.parsed_body.dig("error", "code")).to eq("feed_limit_reached")
        expect(Feed.find_by(url: target_url)).to be_nil
        expect(user.subscriptions.reload.count).to eq(2)
      end

      it "handles race 2: same feed created by another user during fetch, request succeeds with exactly one Feed row" do
        target_url = "https://example.com/race2.xml"
        other_user = create(:user)

        allow(Feeds::Fetcher).to receive(:call).with(target_url, deadline: 5) do
          feed = create(:feed, url: target_url, title: "Concurrent Winner Feed")
          create(:subscription, user: other_user, feed: feed)

          build_fetch_result(title: "Race 2 Fetched Feed")
        end

        post "/api/v1/subscriptions", params: { url: target_url }, headers: headers, as: :json

        expect(response).to have_http_status(:created)
        expect(Feed.where(url: target_url).count).to eq(1)
        expect(user.subscriptions.where(feed: Feed.find_by(url: target_url))).to exist
      end

      it "handles idempotent retry at limit: concurrent request creates same subscription during fetch, returns 200 not 403" do
        feed1 = create(:feed, url: "https://example.com/existing1_idempotent.xml")
        create(:subscription, user: user, feed: feed1)
        expect(user.subscriptions.count).to eq(1)

        target_url = "https://example.com/idempotent.xml"
        concurrent_sub = nil

        allow(Feeds::Fetcher).to receive(:call).with(target_url, deadline: 5) do
          feed = create(:feed, url: target_url, title: "Idempotent Feed")
          concurrent_sub = create(:subscription, user: user, feed: feed)
          build_fetch_result(title: "Idempotent Feed")
        end

        post "/api/v1/subscriptions", params: { url: target_url }, headers: headers, as: :json

        expect(response).to have_http_status(:ok)
        expect(response.parsed_body.dig("subscription", "id")).to eq(concurrent_sub.id.to_s)
        expect(user.subscriptions.reload.count).to eq(2)
        expect(Feed.where(url: target_url).count).to eq(1)
      end
    end

    describe "concurrency gate and interactive deadline" do
      it "passes INTERACTIVE_DEADLINE (5s) to Feeds::Fetcher.call on subscribe" do
        target_url = "https://example.com/deadline_check.xml"
        expect(Feeds::Fetcher).to receive(:call)
          .with(target_url, deadline: Subscriptions::Subscribe::INTERACTIVE_DEADLINE)
          .and_return(build_fetch_result(title: "Deadline Feed"))

        post "/api/v1/subscriptions", params: { url: target_url }, headers: headers, as: :json
        expect(response).to have_http_status(:created)
      end

      it "returns 429 rate_limited with Retry-After 5 when gate is full for a new feed, never calls fetcher and writes nothing" do
        with_env("RAILS_MAX_THREADS" => "3") do
          capacity = Feeds::FetchGate.capacity
          occupy_threads = []
          started_queue = Queue.new
          release_queue = Queue.new

          begin
            capacity.times do
              occupy_threads << Thread.new do
                Feeds::FetchGate.try_run do
                  started_queue << true
                  release_queue.pop
                end
              end
            end

            Timeout.timeout(5) do
              capacity.times { started_queue.pop }
            end

            expect(Feeds::Fetcher).not_to receive(:call)

            target_url = "https://example.com/new_busy.xml"
            expect {
              post "/api/v1/subscriptions", params: { url: target_url }, headers: headers, as: :json
            }.to not_change(Feed, :count)
             .and not_change(Subscription, :count)

            expect(response).to have_http_status(:too_many_requests)
            expect(response.headers["Retry-After"]).to eq("5")
            expect(response.parsed_body).to eq({
              "error" => {
                "code" => "rate_limited",
                "message" => "Too many requests. Please try again later.",
                "details" => {}
              }
            })
          ensure
            capacity.times { release_queue << true }
            occupy_threads.each { |t| t.join(1) }
          end
        end
      end

      it "subscribes or returns existing feed even when gate is full (gate not consulted)" do
        existing_feed = create(:feed, url: "https://example.com/existing_gate.xml")
        create(:subscription, user: user, feed: existing_feed)

        other_user = create(:user)
        shared_feed = create(:feed, url: "https://example.com/shared_gate.xml")
        create(:subscription, user: other_user, feed: shared_feed)

        fresh_user = create(:user, email: "fresh@example.com")
        fresh_token = ApiToken.issue!(user: fresh_user, name: "fresh")[1]
        fresh_headers = { "Authorization" => "Bearer #{fresh_token}" }

        with_env("RAILS_MAX_THREADS" => "3") do
          capacity = Feeds::FetchGate.capacity
          occupy_threads = []
          started = Queue.new
          release = Queue.new

          begin
            capacity.times do
              occupy_threads << Thread.new do
                Feeds::FetchGate.try_run do
                  started << true
                  release.pop
                end
              end
            end
            Timeout.timeout(5) { capacity.times { started.pop } }

            expect(Feeds::FetchGate).not_to receive(:try_run)
            expect(Feeds::Fetcher).not_to receive(:call)

            # 1. Subscribing to already subscribed feed -> 200 OK
            post "/api/v1/subscriptions", params: { url: existing_feed.url }, headers: headers, as: :json
            expect(response).to have_http_status(:ok)

            # 2. Subscribing to existing DB feed from another user -> 201 Created
            post "/api/v1/subscriptions", params: { url: shared_feed.url }, headers: fresh_headers, as: :json
            expect(response).to have_http_status(:created)
          ensure
            capacity.times { release << true }
            occupy_threads.each { |t| t.join(1) }
          end
        end
      end

      it "frees the gate slot after a failing fetch or when fetcher raises" do
        with_env("RAILS_MAX_THREADS" => "3") do
          capacity = Feeds::FetchGate.capacity
          expect(capacity).to eq(2)

          started = Queue.new
          release = Queue.new
          holder_thread = Thread.new do
            Feeds::FetchGate.try_run do
              started << true
              release.pop
            end
          end

          begin
            Timeout.timeout(5) { started.pop }

            # Failing request 1: fetcher returns failure Result (:timeout)
            allow(Feeds::Fetcher).to receive(:call).with("https://example.com/fail1.xml", deadline: 5)
              .and_return(build_fetch_result(success: false, error: :timeout))

            post "/api/v1/subscriptions", params: { url: "https://example.com/fail1.xml" }, headers: headers, as: :json
            expect(response).to have_http_status(:unprocessable_content)

            # Failing request 2: fetcher raises an exception
            allow(Feeds::Fetcher).to receive(:call).with("https://example.com/crash.xml", deadline: 5)
              .and_raise(StandardError, "network blew up")

            expect {
              post "/api/v1/subscriptions", params: { url: "https://example.com/crash.xml" }, headers: headers, as: :json
            }.to raise_error(StandardError, "network blew up")

            # The slot must still be free for a subsequent request
            allow(Feeds::Fetcher).to receive(:call).with("https://example.com/success.xml", deadline: 5)
              .and_return(build_fetch_result(title: "Success Feed"))

            post "/api/v1/subscriptions", params: { url: "https://example.com/success.xml" }, headers: headers, as: :json
            expect(response).to have_http_status(:created)
          ensure
            release << true
            holder_thread.join(1)
          end
        end
      end

      it "never runs HTML sanitization inside a database transaction and passes the interactive budget" do
        baseline_transactions = ActiveRecord::Base.connection.open_transactions
        sanitizer_calls = 0

        allow(Feeds::Refresh).to receive(:prepare)
          .with(anything, budget: Subscriptions::Subscribe::INTERACTIVE_SANITIZE_BUDGET)
          .and_call_original

        allow(Feeds::ContentSanitizer).to receive(:call).and_wrap_original do |original, *args, **kwargs|
          sanitizer_calls += 1
          expect(ActiveRecord::Base.connection.open_transactions).to eq(baseline_transactions)
          original.call(*args, **kwargs)
        end

        target_url = "https://example.com/no_tx_sanitize.xml"
        entry = Feeds::Fetcher::ParsedEntry.new(
          guid: "tx-1",
          url: "https://example.com/posts/1",
          title: "Post 1",
          author: "Alice",
          summary: "<p>Summary</p>",
          content: "<p>Content</p>",
          published_at: 1.day.ago
        )
        allow(Feeds::Fetcher).to receive(:call).with(target_url, deadline: 5)
          .and_return(build_fetch_result(title: "No TX Feed", entries: [ entry ]))

        post "/api/v1/subscriptions", params: { url: target_url }, headers: headers, as: :json

        expect(response).to have_http_status(:created)
        expect(sanitizer_calls).to be > 0
        expect(Feeds::Refresh).to have_received(:prepare)
          .with(anything, budget: Subscriptions::Subscribe::INTERACTIVE_SANITIZE_BUDGET)
      end
    end

    describe "rate limiting" do
      it "limits user to 20 requests per 10 minutes and resets with travel_to" do
        existing_feed = create(:feed, url: "https://example.com/repeat_rate.xml")
        create(:subscription, user: user, feed: existing_feed)

        20.times do
          post "/api/v1/subscriptions", params: { url: existing_feed.url }, headers: headers, as: :json
          expect(response).to have_http_status(:ok)
        end

        post "/api/v1/subscriptions", params: { url: existing_feed.url }, headers: headers, as: :json
        expect(response).to have_http_status(:too_many_requests)
        expect(response.headers["Retry-After"]).to eq("600")
        expect(response.parsed_body.dig("error", "code")).to eq("rate_limited")

        travel 10.minutes + 1.second

        post "/api/v1/subscriptions", params: { url: existing_feed.url }, headers: headers, as: :json
        expect(response).to have_http_status(:ok)
      end
    end
  end

  describe "GET /api/v1/subscriptions" do
    it "lists only the user's own subscriptions ordered by created_at then id" do
      other_user = create(:user)
      other_feed = create(:feed, url: "https://example.com/other_get.xml")
      create(:subscription, user: other_user, feed: other_feed)

      feed1 = create(:feed, url: "https://example.com/g1.xml", title: "Feed 1")
      feed2 = create(:feed, url: "https://example.com/g2.xml", title: "Feed 2")
      sub1 = create(:subscription, user: user, feed: feed1, created_at: 2.days.ago)
      sub2 = create(:subscription, user: user, feed: feed2, created_at: 1.day.ago)

      get "/api/v1/subscriptions", headers: headers

      expect(response).to have_http_status(:ok)
      subs = response.parsed_body["subscriptions"]
      expect(subs.size).to eq(2)
      expect(subs.map { |s| s["id"] }).to eq([ sub1.id.to_s, sub2.id.to_s ])
      expect(subs.map { |s| s["title"] }).to eq([ "Feed 1", "Feed 2" ])
    end

    it "correctly calculates unread_count (read entries not counted, starred-only still unread)" do
      feed = create(:feed, url: "https://example.com/unread_calc.xml")
      create(:subscription, user: user, feed: feed)

      entry_unread = create(:entry, feed: feed, guid: "u1")
      entry_read = create(:entry, feed: feed, guid: "u2")
      entry_starred_only = create(:entry, feed: feed, guid: "u3")

      create(:entry_state, user: user, entry: entry_read, read_at: 1.hour.ago)
      create(:entry_state, user: user, entry: entry_starred_only, starred_at: 1.hour.ago, read_at: nil)

      get "/api/v1/subscriptions", headers: headers

      expect(response).to have_http_status(:ok)
      sub_json = response.parsed_body["subscriptions"].first
      expect(sub_json["unread_count"]).to eq(2)
    end

    it "maintains a constant query count regardless of subscription count (1 vs 5)" do
      # Warm up authentication and user/token creation before query measurement
      get "/api/v1/subscriptions", headers: pro_headers

      feed1 = create(:feed, url: "https://example.com/query_feed_1.xml")
      create(:subscription, user: pro_user, feed: feed1)

      queries_for_1 = count_queries do
        get "/api/v1/subscriptions", headers: pro_headers
      end

      4.times do |i|
        f = create(:feed, url: "https://example.com/extra_query_#{i}.xml")
        create(:subscription, user: pro_user, feed: f)
      end

      queries_for_5 = count_queries do
        get "/api/v1/subscriptions", headers: pro_headers
      end

      expect(queries_for_1).to eq(queries_for_5)
      expect(queries_for_5).to be <= 5
    end
  end

  describe "DELETE /api/v1/subscriptions/:id" do
    it "deletes own subscription (204), preserves feed and entries and other subscriptions" do
      other_user = create(:user)
      feed = create(:feed, url: "https://example.com/shared_del.xml")
      entry = create(:entry, feed: feed, guid: "e1")

      own_sub = create(:subscription, user: user, feed: feed)
      other_sub = create(:subscription, user: other_user, feed: feed)

      delete "/api/v1/subscriptions/#{own_sub.id}", headers: headers

      expect(response).to have_http_status(:no_content)
      expect(Subscription.find_by(id: own_sub.id)).to be_nil
      expect(Feed.find_by(id: feed.id)).to be_present
      expect(Entry.find_by(id: entry.id)).to be_present
      expect(Subscription.find_by(id: other_sub.id)).to be_present
    end

    it "returns 404 not_found when deleting someone else's or an unknown subscription" do
      other_user = create(:user)
      other_sub = create(:subscription, user: other_user)

      delete "/api/v1/subscriptions/#{other_sub.id}", headers: headers
      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body.dig("error", "code")).to eq("not_found")

      delete "/api/v1/subscriptions/999999", headers: headers
      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body.dig("error", "code")).to eq("not_found")
    end

    it "preserves read states on re-subscribing after deleting a subscription" do
      feed = create(:feed, url: "https://example.com/resub.xml", title: "Resub Feed")
      entry1 = create(:entry, feed: feed, guid: "resub-1")
      entry2 = create(:entry, feed: feed, guid: "resub-2")

      sub = create(:subscription, user: user, feed: feed)
      state = create(:entry_state, user: user, entry: entry1, read_at: 1.day.ago)

      # Delete subscription
      delete "/api/v1/subscriptions/#{sub.id}", headers: headers
      expect(response).to have_http_status(:no_content)

      # Re-subscribe to same feed
      post "/api/v1/subscriptions", params: { url: feed.url }, headers: headers, as: :json
      expect(response).to have_http_status(:created)

      sub_json = response.parsed_body["subscription"]
      expect(sub_json["unread_count"]).to eq(1) # entry1 is still read, entry2 is unread
      expect(state.reload.read_at).to be_present
    end
  end
end
