# frozen_string_literal: true

require "rails_helper"

RSpec.describe Feeds::UrlPolicy do
  describe ".validate_feed_url" do
    it "accepts http and https with default and explicit ports 80/443, and upper-case scheme/host" do
      expect(described_class.validate_feed_url("http://example.com/feed")).to be_a(URI::HTTP)
      expect(described_class.validate_feed_url("https://example.com/feed")).to be_a(URI::HTTPS)
      expect(described_class.validate_feed_url("http://example.com:80/feed")).to be_a(URI::HTTP)
      expect(described_class.validate_feed_url("https://example.com:443/feed")).to be_a(URI::HTTPS)
      expect(described_class.validate_feed_url("HTTP://EXAMPLE.COM/feed")).to be_a(URI::HTTP)
      expect(described_class.validate_feed_url("HTTPS://EXAMPLE.COM:443/feed")).to be_a(URI::HTTPS)
    end

    it "accepts exact maximum length of 2048 characters" do
      exact_2048 = "https://example.com/" + ("a" * (2048 - 20))
      expect(exact_2048.length).to eq(2048)
      expect(described_class.validate_feed_url(exact_2048)).to be_a(URI::HTTPS)
    end

    it "returns nil for invalid, non-string, or disallowed feed URLs" do
      too_long = "https://example.com/" + ("a" * (2049 - 20))
      expect(too_long.length).to eq(2049)

      expect(described_class.validate_feed_url(nil)).to be_nil
      expect(described_class.validate_feed_url(12_345)).to be_nil
      expect(described_class.validate_feed_url(:symbol_url)).to be_nil
      expect(described_class.validate_feed_url([ "https://example.com" ])).to be_nil
      expect(described_class.validate_feed_url(too_long)).to be_nil
      expect(described_class.validate_feed_url("ftp://example.com/feed.xml")).to be_nil
      expect(described_class.validate_feed_url("javascript:alert(1)")).to be_nil
      expect(described_class.validate_feed_url("data:text/html,payload")).to be_nil
      expect(described_class.validate_feed_url("mailto:user@example.com")).to be_nil
      expect(described_class.validate_feed_url("http://")).to be_nil
      expect(described_class.validate_feed_url("http:///path")).to be_nil
      expect(described_class.validate_feed_url("http://:80/feed")).to be_nil
      expect(described_class.validate_feed_url("http://user@example.com/feed")).to be_nil
      expect(described_class.validate_feed_url("http://user:password@example.com/feed")).to be_nil
      expect(described_class.validate_feed_url("http://example.com:8080/feed")).to be_nil
      expect(described_class.validate_feed_url("http://example.com:0/feed")).to be_nil
      expect(described_class.validate_feed_url("not a url")).to be_nil
      expect(described_class.validate_feed_url("/relative/path.xml")).to be_nil
      expect(described_class.validate_feed_url("http://example.com/feed with spaces")).to be_nil
    end
  end

  describe ".normalize_and_validate_feed_url" do
    it "normalizes variants of a feed URL into a canonical form and is idempotent" do
      canonical = "http://example.com/feed"

      expect(described_class.normalize_and_validate_feed_url("HTTP://EXAMPLE.COM/feed")).to eq(canonical)
      expect(described_class.normalize_and_validate_feed_url("http://example.com/feed#fragment")).to eq(canonical)
      expect(described_class.normalize_and_validate_feed_url("http://example.com/")).to eq("http://example.com")

      normalized = described_class.normalize_and_validate_feed_url("HTTP://EXAMPLE.COM/feed#fragment")
      expect(described_class.normalize_and_validate_feed_url(normalized)).to eq(normalized)
    end

    it "returns nil for surrounding whitespace as the policy validates raw input before stripping" do
      expect(described_class.normalize_and_validate_feed_url("  http://example.com/feed  ")).to be_nil
    end

    it "returns nil for every invalid URL case" do
      too_long = "https://example.com/" + ("a" * 2030)
      invalid_cases = [
        nil,
        12_345,
        too_long,
        "ftp://example.com/feed.xml",
        "javascript:alert(1)",
        "data:text/html,payload",
        "mailto:user@example.com",
        "http://",
        "http://user:pass@example.com/feed",
        "http://example.com:8080/feed",
        "http://example.com:0/feed",
        "not-a-valid-url",
        "/relative/path.xml",
        "http://example.com/space in path"
      ]

      invalid_cases.each do |input|
        expect(described_class.normalize_and_validate_feed_url(input)).to be_nil
      end
    end

    it "returns nil when normalization causes the URL to exceed 2048 characters" do
      allow(described_class).to receive(:normalize_feed_url).and_return("https://example.com/" + ("a" * 2040))
      expect(described_class.normalize_and_validate_feed_url("https://example.com/feed")).to be_nil
    end
  end

  describe ".valid_site_url? and .clean_site_url" do
    it "accepts valid http and https site URLs and cleans them by stripping surrounding whitespace" do
      expect(described_class.valid_site_url?("http://example.com")).to be true
      expect(described_class.clean_site_url("http://example.com")).to eq("http://example.com")

      expect(described_class.valid_site_url?("https://example.com/blog")).to be true
      expect(described_class.clean_site_url("https://example.com/blog")).to eq("https://example.com/blog")

      expect(described_class.valid_site_url?("  https://example.com/site  ")).to be true
      expect(described_class.clean_site_url("  https://example.com/site  ")).to eq("https://example.com/site")
    end

    it "rejects invalid, blank, non-string, or disallowed site URLs" do
      too_long = "https://example.com/" + ("a" * 2030)
      invalid_sites = [
        nil,
        "",
        "   ",
        12_345,
        :not_a_string,
        "ftp://example.com",
        "javascript:alert(1)",
        "https://user:pass@example.com",
        "https://",
        too_long
      ]

      invalid_sites.each do |site|
        expect(described_class.valid_site_url?(site)).to be false
        expect(described_class.clean_site_url(site)).to be_nil
      end
    end
  end

  describe "network isolation" do
    before do
      allow(Resolv).to receive(:getaddress).and_raise("Network/DNS call forbidden in Feeds::UrlPolicy")
      allow(Resolv).to receive(:getaddresses).and_raise("Network/DNS call forbidden in Feeds::UrlPolicy")
      allow(Socket).to receive(:getaddrinfo).and_raise("Network/DNS call forbidden in Feeds::UrlPolicy")
      allow(TCPSocket).to receive(:open).and_raise("Network/DNS call forbidden in Feeds::UrlPolicy")
      allow(Net::HTTP).to receive(:start).and_raise("Network/DNS call forbidden in Feeds::UrlPolicy")
      allow(Net::HTTP).to receive(:new).and_raise("Network/DNS call forbidden in Feeds::UrlPolicy")
    end

    it "never touches DNS or network when calling public methods with valid hostname URLs" do
      valid_feed = "https://example.com/feed.xml"
      valid_site = "https://example.com"

      expect {
        described_class.validate_feed_url(valid_feed)
        described_class.normalize_feed_url(valid_feed)
        described_class.normalize_and_validate_feed_url(valid_feed)
        described_class.valid_site_url?(valid_site)
        described_class.clean_site_url(valid_site)
      }.not_to raise_error
    end
  end
end
