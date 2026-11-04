# frozen_string_literal: true

require "rails_helper"

RSpec.describe "OPML Import and Subscriptions URL Parity", type: :request do
  let(:user_a) { create(:user, plan: "pro") }
  let(:token_a) { ApiToken.issue!(user: user_a, name: "device-a")[1] }
  let(:headers_a) { { "Authorization" => "Bearer #{token_a}" } }

  let(:user_b) { create(:user, plan: "pro") }

  def build_fetch_result(title: "Parity Test Feed")
    feed_data = Feeds::Fetcher::ParsedFeed.new(
      title: title,
      site_url: "https://example.com",
      entries: []
    )

    Feeds::Fetcher::Result.new(
      success: true,
      error: nil,
      message: nil,
      status: 200,
      final_url: "https://example.com/feed.xml",
      etag: nil,
      last_modified: nil,
      feed: feed_data
    )
  end

  ACCEPTED_VARIANTS = [
    "HTTP://example.com/feed1.xml",
    "https://EXAMPLE.COM/feed2.xml",
    "hTtPs://ExAmPlE.cOm/feed3.xml",
    "https://example.com/feed4.xml#section1",
    "https://example.com/#top",
    "https://example.com/",
    "http://example.com:80/feed5.xml",
    "https://example.com:443/feed6.xml",
    "https://example.com/feed7.xml?format=rss",
    "https://example.com/feed8.xml?a=1&b=2",
    "https://example.com/my%20feed.xml",
    "https://example.com/feeds/",
    "https://example.com/Feeds/News.xml",
    "https://example.com/feed9.xml?category=tech%20news",
    "https://sub-domain.example.com/feed10.xml",
    "https://example.com/a/b/../c/feed11.xml"
  ].freeze

  REJECTED_URLS = [
    "ftp://example.com/feed.xml",
    "javascript:alert(1)",
    "http://example.com:8080/feed.xml",
    "https://example.com/" + ("a" * 2030),
    "not_a_valid_url",
    "data:text/html,payload",
    "mailto:user@example.com"
  ].freeze

  describe "accepted URL variants parity" do
    ACCEPTED_VARIANTS.each do |url_variant|
      it "maps #{url_variant} to exactly ONE Feed row followed by both user A and user B with identical Feed.url" do
        normalized_form = Feed.normalize_value_for(:url, url_variant)

        allow(Feeds::Fetcher).to receive(:call).and_wrap_original do |original, *args, **kwargs|
          target = args.first
          if Feeds::UrlPolicy.validate_feed_url(target)
            build_fetch_result
          else
            original.call(*args, **kwargs)
          end
        end

        post "/api/v1/subscriptions", params: { url: url_variant }, headers: headers_a, as: :json
        expect(response).to have_http_status(:created)

        import_result = Opml::Import.call(user: user_b, outlines: [ { url: url_variant } ])
        expect(import_result.imported).to eq(1)
        expect(import_result.errors).to be_empty

        feed_rows = Feed.where(url: normalized_form)
        expect(feed_rows.count).to eq(1)

        shared_feed = feed_rows.first
        sub_a = user_a.subscriptions.find_by(feed: shared_feed)
        sub_b = user_b.subscriptions.find_by(feed: shared_feed)

        expect(sub_a).not_to be_nil
        expect(sub_b).not_to be_nil
        expect(sub_a.feed.url).to eq(sub_b.feed.url)
        expect(sub_a.feed.url.bytes).to eq(sub_b.feed.url.bytes)
      end
    end
  end

  describe "rejected URLs parity" do
    REJECTED_URLS.each do |bad_url|
      it "rejects #{bad_url.truncate(40)} with invalid_feed_url through both POST /subscriptions and Opml::Import" do
        post "/api/v1/subscriptions", params: { url: bad_url }, headers: headers_a, as: :json
        expect(response).to have_http_status(:unprocessable_content)
        expect(response.parsed_body.dig("error", "code")).to eq("invalid_feed_url")

        import_result = Opml::Import.call(user: user_b, outlines: [ { url: bad_url } ])
        expect(import_result.imported).to eq(0)
        expect(import_result.errors.first[:code]).to eq("invalid_feed_url")
      end
    end
  end

  describe "credential safety and whitespace pipeline parity" do
    it "ensures credentials never reach the feeds table through either route" do
      url_with_credentials = "https://user:secret@Example.com/feed.xml"
      allow(Feeds::Fetcher).to receive(:call).and_return(build_fetch_result)

      post "/api/v1/subscriptions", params: { url: url_with_credentials }, headers: headers_a, as: :json

      import_result = Opml::Import.call(user: user_b, outlines: [ { url: url_with_credentials } ])
      expect(import_result.imported).to eq(0)
      expect(import_result.errors.first[:code]).to eq("invalid_feed_url")

      expect(Feed.where("url LIKE ? OR url LIKE ?", "%secret%", "%@%")).to be_empty
    end

    it "yields the same Feed.url for surrounding whitespace in OPML xmlUrl pipeline as POST /subscriptions" do
      whitespace_str = "  https://example.com/whitespace_feed.xml  "
      opml_xml = %(<opml version="2.0"><body><outline type="rss" xmlUrl="#{whitespace_str}"/></body></opml>)

      allow(Feeds::Fetcher).to receive(:call).and_return(build_fetch_result)

      post "/api/v1/subscriptions", params: { url: whitespace_str }, headers: headers_a, as: :json
      expect(response).to have_http_status(:created)

      parse_result = Opml::Parser.parse(opml_xml)
      expect(parse_result).to be_ok

      import_result = Opml::Import.call(user: user_b, outlines: parse_result.outlines)
      expect(import_result.imported).to eq(1)

      feed_rows = Feed.where(url: "https://example.com/whitespace_feed.xml")
      expect(feed_rows.count).to eq(1)

      feed_a = user_a.subscriptions.find_by(feed: feed_rows.first)&.feed
      feed_b = user_b.subscriptions.find_by(feed: feed_rows.first)&.feed

      expect(feed_a).not_to be_nil
      expect(feed_b).not_to be_nil
      expect(feed_a.url).to eq(feed_b.url)
      expect(feed_a.url.bytes).to eq(feed_b.url.bytes)
    end

    it "is never more permissive than Feeds::Fetcher URL validation" do
      urls_to_test = [
        "http://example.com/perm1.xml",
        "https://example.com/perm2.xml",
        "HTTP://EXAMPLE.COM/perm3.xml",
        "https://example.com:443/perm4.xml",
        "http://example.com:80/perm5.xml",
        "https://example.com/perm6.xml#section",
        "https://example.com/",
        "https://example.com/perm7.xml?k=v",
        "https://sub.domain.example.com/perm8.xml",
        "https://example.com/perm%209.xml",
        "https://example.com/Mixed/Case/perm10.xml"
      ]

      outlines = urls_to_test.map { |u| { url: u } }
      result = Opml::Import.call(user: user_b, outlines: outlines)

      expect(result.imported).to eq(urls_to_test.size)
      expect(result.errors).to be_empty

      urls_to_test.each do |input_url|
        normalized_url = Feeds::UrlPolicy.normalize_and_validate_feed_url(input_url)
        expect(normalized_url).not_to be_nil
        expect(Feeds::UrlPolicy.validate_feed_url(normalized_url)).to be_a(URI::Generic)
      end
    end
  end
end
