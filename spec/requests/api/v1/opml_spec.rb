# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::V1::Opml", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  let(:user) { create(:user, email: "alice@example.com", plan: "pro") }
  let(:token) { ApiToken.issue!(user: user, name: "laptop")[1] }
  let(:headers) { { "Authorization" => "Bearer #{token}" } }

  let(:free_user) { create(:user, email: "bob@example.com", plan: "free") }
  let(:free_token) { ApiToken.issue!(user: free_user, name: "laptop-free")[1] }
  let(:free_headers) { { "Authorization" => "Bearer #{free_token}" } }

  def count_queries(&block)
    queries = []
    collector = ->(_name, _start, _finish, _id, payload) do
      sql = payload[:sql].to_s.strip
      name = payload[:name].to_s
      unless name == "SCHEMA" || name == "TRANSACTION" || sql.match?(/\A(BEGIN|COMMIT|ROLLBACK|SAVEPOINT|RELEASE)\b/i)
        queries << sql
      end
    end
    ActiveSupport::Notifications.subscribed(collector, "sql.active_record", &block)
    queries.size
  end

  def build_upload(content, filename: "subscriptions.opml")
    Rack::Test::UploadedFile.new(StringIO.new(content), "application/xml", original_filename: filename)
  end

  describe "POST /api/v1/opml/import" do
    context "authentication" do
      it "returns 401 when no token is provided" do
        upload = build_upload("<opml version=\"2.0\"><body></body></opml>")
        post "/api/v1/opml/import", params: { file: upload }

        expect(response).to have_http_status(:unauthorized)
        expect(response.headers["WWW-Authenticate"]).to eq("Bearer")
        expect(response.parsed_body.dig("error", "code")).to eq("unauthorized")
      end

      it "returns 401 when token is revoked" do
        raw_token = ApiToken.issue!(user: user, name: "revoked-token")[1]
        ApiToken.find_by(token_digest: ApiToken.digest(raw_token)).update!(revoked_at: Time.current)

        upload = build_upload("<opml version=\"2.0\"><body></body></opml>")
        post "/api/v1/opml/import",
             params: { file: upload },
             headers: { "Authorization" => "Bearer #{raw_token}" }

        expect(response).to have_http_status(:unauthorized)
        expect(response.parsed_body.dig("error", "code")).to eq("unauthorized")
      end
    end

    context "happy path" do
      it "imports feeds from a valid OPML with folders, sets next_fetch_at, and integrates with GET /subscriptions and GET /sync" do
        opml_content = <<~XML
          <?xml version="1.0" encoding="UTF-8"?>
          <opml version="2.0">
            <head><title>My Feeds</title></head>
            <body>
              <outline text="Tech">
                <outline text="Feed 1" title="Feed 1" type="rss" xmlUrl="https://example.com/feed1.xml" htmlUrl="https://example.com/site1"/>
                <outline text="Feed 2" title="Feed 2" type="rss" xmlUrl="https://example.com/feed2.xml"/>
              </outline>
              <outline text="Feed 3" title="Feed 3" type="rss" xmlUrl="https://example.com/feed3.xml"/>
            </body>
          </opml>
        XML

        upload = build_upload(opml_content)

        expect {
          post "/api/v1/opml/import", params: { file: upload }, headers: headers
        }.to change(Feed, :count).by(3)
         .and change(user.subscriptions, :count).by(3)

        expect(response).to have_http_status(:ok)
        expect(response.parsed_body.keys).to match_array(%w[imported skipped errors])
        expect(response.parsed_body["imported"]).to eq(3)
        expect(response.parsed_body["skipped"]).to eq(0)
        expect(response.parsed_body["errors"]).to eq([])

        # Feed attributes: next_fetch_at set, no entries
        new_feeds = Feed.where(url: [ "https://example.com/feed1.xml", "https://example.com/feed2.xml", "https://example.com/feed3.xml" ])
        expect(new_feeds.count).to eq(3)
        new_feeds.each do |feed|
          expect(feed.next_fetch_at).not_to be_nil
          expect(feed.entries.count).to eq(0)
        end

        # GET /api/v1/subscriptions lists them in subscription order with unread_count 0
        get "/api/v1/subscriptions", headers: headers
        expect(response).to have_http_status(:ok)
        subs = response.parsed_body["subscriptions"]
        expect(subs.size).to eq(3)
        expect(subs.map { |s| s["unread_count"] }).to eq([ 0, 0, 0 ])
        expect(subs.map { |s| s["url"] }).to eq([
          "https://example.com/feed1.xml",
          "https://example.com/feed2.xml",
          "https://example.com/feed3.xml"
        ])

        # GET /api/v1/sync snapshot contains them
        get "/api/v1/sync", headers: headers
        expect(response).to have_http_status(:ok)
        sync_subs = response.parsed_body["subscriptions"]
        expect(sync_subs.map { |s| s["url"] }).to match_array([
          "https://example.com/feed1.xml",
          "https://example.com/feed2.xml",
          "https://example.com/feed3.xml"
        ])
      end
    end

    context "plan limits and deduplication" do
      it "imports up to plan limit for a free user, reporting feed_limit_reached for over-limit outlines without creating feed rows" do
        opml_content = <<~XML
          <opml version="2.0">
            <body>
              <outline type="rss" xmlUrl="https://example.com/free1.xml"/>
              <outline type="rss" xmlUrl="https://example.com/free2.xml"/>
              <outline type="rss" xmlUrl="https://example.com/free3.xml"/>
              <outline type="rss" xmlUrl="https://example.com/free4.xml"/>
            </body>
          </opml>
        XML

        upload = build_upload(opml_content)

        expect {
          post "/api/v1/opml/import", params: { file: upload }, headers: free_headers
        }.to change(Feed, :count).by(2)
         .and change(free_user.subscriptions, :count).by(2)

        expect(response).to have_http_status(:ok)
        expect(response.parsed_body["imported"]).to eq(2)
        expect(response.parsed_body["skipped"]).to eq(0)
        expect(response.parsed_body["errors"]).to eq([
          { "url" => "https://example.com/free3.xml", "code" => "feed_limit_reached" },
          { "url" => "https://example.com/free4.xml", "code" => "feed_limit_reached" }
        ])

        expect(Feed.exists?(url: "https://example.com/free1.xml")).to be true
        expect(Feed.exists?(url: "https://example.com/free2.xml")).to be true
        expect(Feed.exists?(url: "https://example.com/free3.xml")).to be false
        expect(Feed.exists?(url: "https://example.com/free4.xml")).to be false
      end

      it "skips an already followed feed and leaves other user subscriptions untouched" do
        other_user = create(:user)
        other_feed = create(:feed, url: "https://example.com/other_untouched.xml")
        create(:subscription, user: other_user, feed: other_feed)

        followed_feed = create(:feed, url: "https://example.com/already_followed.xml")
        create(:subscription, user: user, feed: followed_feed)

        opml_content = <<~XML
          <opml version="2.0">
            <body>
              <outline type="rss" xmlUrl="https://example.com/already_followed.xml"/>
              <outline type="rss" xmlUrl="https://example.com/brand_new.xml"/>
            </body>
          </opml>
        XML

        upload = build_upload(opml_content)

        post "/api/v1/opml/import", params: { file: upload }, headers: headers

        expect(response).to have_http_status(:ok)
        expect(response.parsed_body["imported"]).to eq(1)
        expect(response.parsed_body["skipped"]).to eq(1)
        expect(response.parsed_body["errors"]).to eq([])

        expect(other_user.subscriptions.reload.count).to eq(1)
      end

      it "returns 200 with imported 0 and invalid_feed_url errors when all URLs are invalid" do
        opml_content = <<~XML
          <opml version="2.0">
            <body>
              <outline type="rss" xmlUrl="ftp://example.com/feed.xml"/>
              <outline type="rss" xmlUrl="javascript:alert(1)"/>
            </body>
          </opml>
        XML

        upload = build_upload(opml_content)

        post "/api/v1/opml/import", params: { file: upload }, headers: headers

        expect(response).to have_http_status(:ok)
        expect(response.parsed_body["imported"]).to eq(0)
        expect(response.parsed_body["skipped"]).to eq(0)
        expect(response.parsed_body["errors"].map { |e| e["code"] }).to eq([ "invalid_feed_url", "invalid_feed_url" ])
      end

      it "imports 0 and skips all when uploading the exact same OPML twice" do
        opml_content = <<~XML
          <opml version="2.0">
            <body>
              <outline type="rss" xmlUrl="https://example.com/twice1.xml"/>
              <outline type="rss" xmlUrl="https://example.com/twice2.xml"/>
            </body>
          </opml>
        XML

        upload1 = build_upload(opml_content)
        post "/api/v1/opml/import", params: { file: upload1 }, headers: headers
        expect(response.parsed_body["imported"]).to eq(2)

        upload2 = build_upload(opml_content)
        post "/api/v1/opml/import", params: { file: upload2 }, headers: headers
        expect(response.parsed_body["imported"]).to eq(0)
        expect(response.parsed_body["skipped"]).to eq(2)
        expect(response.parsed_body["errors"]).to eq([])
      end
    end

    context "file parameter validation" do
      it "returns 400 bad_request with details.param 'file' when file is missing, plain string, array, hash, or JSON body" do
        cases = [
          {},
          { file: "plain string not an uploaded file" },
          { file: [ "array", "form" ] },
          { file: { "nested" => "hash" } }
        ]

        expect {
          cases.each do |bad_params|
            post "/api/v1/opml/import", params: bad_params, headers: headers

            expect(response).to have_http_status(:bad_request)
            expect(response.parsed_body).to eq({
              "error" => {
                "code" => "bad_request",
                "message" => "Missing or invalid file parameter",
                "details" => { "param" => "file" }
              }
            })
          end

          # JSON body instead of multipart
          post "/api/v1/opml/import", params: { file: "not a file" }, headers: headers, as: :json
          expect(response).to have_http_status(:bad_request)
          expect(response.parsed_body.dig("error", "code")).to eq("bad_request")
          expect(response.parsed_body.dig("error", "details", "param")).to eq("file")
        }.to not_change(Feed, :count)
         .and not_change(Subscription, :count)
         .and not_change(user.subscriptions, :count)
      end
    end

    context "invalid_opml error handling" do
      let(:canary_path) { "/tmp/opml_canary_#{SecureRandom.hex(8)}.txt" }

      before do
        File.write(canary_path, "CANARY_SECRET_DATA_LEAK")
      end

      after do
        FileUtils.rm_f(canary_path)
      end

      it "rejects malformed XML, DOCTYPE with entity, not_opml, too_large, too_many_outlines with 422 and never echoes file content" do
        too_many_outlines_xml = "<opml version=\"2.0\"><body>" + (1..501).map { |i| "<outline type=\"rss\" xmlUrl=\"https://example.com/#{i}\"/>" }.join + "</body></opml>"
        too_large_xml = "<opml version=\"2.0\"><body>" + ("<!-- " + ("x" * 1_048_580) + " -->") + "</body></opml>"
        doctype_xml = "<!DOCTYPE opml SYSTEM \"#{canary_path}\"><opml version=\"2.0\"><body></body></opml>"

        invalid_cases = [
          { xml: "not xml at all << >>", reason: "malformed" },
          { xml: doctype_xml, reason: "doctype_not_allowed" },
          { xml: "<rss version=\"2.0\"><channel></channel></rss>", reason: "not_opml" },
          { xml: too_large_xml, reason: "too_large" },
          { xml: too_many_outlines_xml, reason: "too_many_outlines" }
        ]

        expect {
          invalid_cases.each do |tc|
            upload = build_upload(tc[:xml])
            post "/api/v1/opml/import", params: { file: upload }, headers: headers

            expect(response).to have_http_status(:unprocessable_content)
            expect(response.parsed_body).to eq({
              "error" => {
                "code" => "invalid_opml",
                "message" => "Invalid OPML file",
                "details" => { "reason" => tc[:reason] }
              }
            })
            expect(response.body).not_to include("CANARY_SECRET_DATA_LEAK")
            expect(response.body).not_to include("x" * 100)
          end
        }.to not_change(Feed, :count)
         .and not_change(Subscription, :count)
         .and not_change(user.subscriptions, :count)
      end

      it "accepts an OPML document of exactly 1 MB (1_048_576 bytes)" do
        base_xml = "<opml version=\"2.0\"><body><!-- %s --></body></opml>"
        comment_length = 1_048_576 - base_xml.bytesize + 2
        exact_1mb_xml = format(base_xml, "x" * comment_length)
        expect(exact_1mb_xml.bytesize).to eq(1_048_576)

        upload = build_upload(exact_1mb_xml)
        post "/api/v1/opml/import", params: { file: upload }, headers: headers

        expect(response).to have_http_status(:ok)
        expect(response.parsed_body["imported"]).to eq(0)
      end

      it "returns a clean 400 for a garbage multipart body without echoing payload or crashing with 500" do
        post "/api/v1/opml/import",
             headers: headers.merge("Accept" => "application/json", "CONTENT_TYPE" => "multipart/form-data; boundary=---broken-boundary"),
             params: "garbage broken body without valid boundary delimiter"

        expect(response).to have_http_status(:bad_request)
        expect(response.content_type).to start_with("application/json")
        expect(response.body).not_to include("garbage broken body")
      end
    end

    context "rate limiting" do
      it "limits user to 5 imports per 10 minutes, counting invalid files, without affecting other users or export" do
        other_user = create(:user, email: "charlie@example.com", plan: "pro")
        other_token = ApiToken.issue!(user: other_user, name: "laptop-other")[1]
        other_headers = { "Authorization" => "Bearer #{other_token}" }

        # 5 attempts (mixing valid and invalid) all count toward rate limit
        5.times do |i|
          content = if i.even?
            "<opml version=\"2.0\"><body></body></opml>"
          else
            "malformed xml"
          end

          upload = build_upload(content)
          post "/api/v1/opml/import", params: { file: upload }, headers: headers
          expect([ 200, 422 ]).to include(response.status)
        end

        # 6th attempt within window is rate limited
        upload6 = build_upload("<opml version=\"2.0\"><body></body></opml>")
        post "/api/v1/opml/import", params: { file: upload6 }, headers: headers

        expect(response).to have_http_status(:too_many_requests)
        expect(response.headers["Retry-After"]).to eq("600")
        expect(response.parsed_body.dig("error", "code")).to eq("rate_limited")

        # Export is unaffected
        get "/api/v1/opml/export", headers: headers
        expect(response).to have_http_status(:ok)

        # Another user is unaffected
        post "/api/v1/opml/import", params: { file: upload6 }, headers: other_headers
        expect(response).to have_http_status(:ok)

        # Resets after window
        travel 10.minutes + 1.second

        post "/api/v1/opml/import", params: { file: upload6 }, headers: headers
        expect(response).to have_http_status(:ok)
      end

      it "resets the rate limit window with travel_to after 10 minutes, allowing 5 imports again before blocking" do
        start_time = Time.current

        travel_to(start_time) do
          upload_invalid = build_upload("malformed xml")
          upload_valid = build_upload("<opml version=\"2.0\"><body></body></opml>")

          # 5 imports pass (one of them an invalid file)
          post "/api/v1/opml/import", params: { file: upload_invalid }, headers: headers
          expect(response).to have_http_status(:unprocessable_content)

          4.times do
            post "/api/v1/opml/import", params: { file: upload_valid }, headers: headers
            expect(response).to have_http_status(:ok)
          end

          # the 6th => 429 rate_limited with Retry-After
          post "/api/v1/opml/import", params: { file: upload_valid }, headers: headers
          expect(response).to have_http_status(:too_many_requests)
          expect(response.headers["Retry-After"]).to eq("600")
          expect(response.parsed_body.dig("error", "code")).to eq("rate_limited")
        end

        # travel_to 9 minutes 59 seconds after the first request => still 429
        travel_to(start_time + 9.minutes + 59.seconds) do
          upload_valid = build_upload("<opml version=\"2.0\"><body></body></opml>")
          post "/api/v1/opml/import", params: { file: upload_valid }, headers: headers

          expect(response).to have_http_status(:too_many_requests)
          expect(response.headers["Retry-After"]).to eq("600")
          expect(response.parsed_body.dig("error", "code")).to eq("rate_limited")
        end

        # travel_to 10 minutes + 1 second after the first request => the next import is NOT 429
        # (it passes or answers 422, whichever the body gives), and a second window then allows 5 again and blocks the 6th
        travel_to(start_time + 10.minutes + 1.second) do
          upload_valid = build_upload("<opml version=\"2.0\"><body></body></opml>")

          # next import is NOT 429
          post "/api/v1/opml/import", params: { file: upload_valid }, headers: headers
          expect(response).not_to have_http_status(:too_many_requests)
          expect(response).to have_http_status(:ok)

          # second window allows 5 again (1 already done + 4 more = 5)
          4.times do
            post "/api/v1/opml/import", params: { file: upload_valid }, headers: headers
            expect(response).not_to have_http_status(:too_many_requests)
            expect(response).to have_http_status(:ok)
          end

          # and blocks the 6th
          post "/api/v1/opml/import", params: { file: upload_valid }, headers: headers
          expect(response).to have_http_status(:too_many_requests)
          expect(response.headers["Retry-After"]).to eq("600")
          expect(response.parsed_body.dig("error", "code")).to eq("rate_limited")
        end
      end
    end

    context "performance and scale" do
      it "executes a constant number of SQL queries for 5 vs 100 outlines" do
        opml_5 = "<opml version=\"2.0\"><body>" + (1..5).map { |i| "<outline type=\"rss\" xmlUrl=\"https://example.com/q5_#{i}.xml\"/>" }.join + "</body></opml>"
        opml_100 = "<opml version=\"2.0\"><body>" + (1..100).map { |i| "<outline type=\"rss\" xmlUrl=\"https://example.com/q100_#{i}.xml\"/>" }.join + "</body></opml>"

        u5 = create(:user, plan: "pro")
        t5 = ApiToken.issue!(user: u5, name: "t5")[1]
        h5 = { "Authorization" => "Bearer #{t5}" }

        u100 = create(:user, plan: "pro")
        t100 = ApiToken.issue!(user: u100, name: "t100")[1]
        h100 = { "Authorization" => "Bearer #{t100}" }

        queries_5 = count_queries do
          post "/api/v1/opml/import", params: { file: build_upload(opml_5) }, headers: h5
        end

        queries_100 = count_queries do
          post "/api/v1/opml/import", params: { file: build_upload(opml_100) }, headers: h100
        end

        expect(response).to have_http_status(:ok)
        expect(queries_5).to eq(queries_100)
      end
    end
  end

  describe "GET /api/v1/opml/export" do
    context "authentication" do
      it "returns 401 when no token is provided" do
        get "/api/v1/opml/export"

        expect(response).to have_http_status(:unauthorized)
        expect(response.headers["WWW-Authenticate"]).to eq("Bearer")
        expect(response.parsed_body.dig("error", "code")).to eq("unauthorized")
      end

      it "returns 401 when token is revoked" do
        raw_token = ApiToken.issue!(user: user, name: "revoked-export")[1]
        ApiToken.find_by(token_digest: ApiToken.digest(raw_token)).update!(revoked_at: Time.current)

        get "/api/v1/opml/export", headers: { "Authorization" => "Bearer #{raw_token}" }

        expect(response).to have_http_status(:unauthorized)
        expect(response.parsed_body.dig("error", "code")).to eq("unauthorized")
      end
    end

    context "happy path and headers" do
      it "exports only current user subscriptions in order with correct media type, charset, and Content-Disposition" do
        other_user = create(:user)
        other_feed = create(:feed, url: "https://example.com/other_export.xml")
        create(:subscription, user: other_user, feed: other_feed)

        feed1 = create(:feed, url: "https://example.com/export1.xml", title: "Feed 1", site_url: "https://example.com/site1")
        feed2 = create(:feed, url: "https://example.com/export2.xml", title: "Feed 2")
        create(:subscription, user: user, feed: feed1, created_at: 2.hours.ago)
        create(:subscription, user: user, feed: feed2, created_at: 1.hour.ago)

        get "/api/v1/opml/export", headers: headers

        expect(response).to have_http_status(:ok)
        expect(response.media_type).to eq("application/xml")
        expect(response.charset).to eq("utf-8")
        expect(response.headers["Content-Disposition"]).to start_with('attachment; filename="cerrynt-subscriptions.opml"')

        # Parses as valid OPML 2.0 with Opml::Parser
        parse_result = Opml::Parser.parse(response.body)
        expect(parse_result).to be_ok
        expect(parse_result.outlines.map { |o| o[:url] }).to eq([
          "https://example.com/export1.xml",
          "https://example.com/export2.xml"
        ])
        expect(response.body).not_to include("https://example.com/other_export.xml")
      end

      it "returns a valid OPML document with zero outlines when user has no subscriptions" do
        empty_user = create(:user, plan: "pro")
        empty_token = ApiToken.issue!(user: empty_user, name: "empty")[1]

        get "/api/v1/opml/export", headers: { "Authorization" => "Bearer #{empty_token}" }

        expect(response).to have_http_status(:ok)
        parse_result = Opml::Parser.parse(response.body)
        expect(parse_result).to be_ok
        expect(parse_result.outlines).to be_empty
      end
    end

    context "HTTP round-trip" do
      it "allows user A to export and user B to import the downloaded body with matching URLs and no extra feed rows" do
        feed1 = create(:feed, url: "https://example.com/rt1.xml", title: "RT 1")
        feed2 = create(:feed, url: "https://example.com/rt2.xml", title: "RT 2")
        create(:subscription, user: user, feed: feed1)
        create(:subscription, user: user, feed: feed2)

        initial_feed_count = Feed.count

        get "/api/v1/opml/export", headers: headers
        expect(response).to have_http_status(:ok)
        exported_body = response.body

        user_b = create(:user, plan: "pro")
        token_b = ApiToken.issue!(user: user_b, name: "b")[1]
        headers_b = { "Authorization" => "Bearer #{token_b}" }

        upload = build_upload(exported_body)
        post "/api/v1/opml/import", params: { file: upload }, headers: headers_b

        expect(response).to have_http_status(:ok)
        expect(response.parsed_body["imported"]).to eq(2)
        expect(response.parsed_body["skipped"]).to eq(0)
        expect(response.parsed_body["errors"]).to be_empty

        # No new feed rows created; existing feeds reused
        expect(Feed.count).to eq(initial_feed_count)
        expect(user_b.subscriptions.count).to eq(2)
        expect(user_b.subscriptions.map { |s| s.feed.url }).to match_array([
          "https://example.com/rt1.xml",
          "https://example.com/rt2.xml"
        ])
      end
    end
  end
end
