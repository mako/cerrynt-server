require 'rails_helper'
require 'resolv'

RSpec.describe Feeds::Fetcher do
  let(:public_ip) { "93.184.216.34" }
  let(:fake_resolver) { ->(_host) { [ public_ip ] } }
  let(:rss_fixture) { file_fixture("feeds/rss20.xml").read }
  let(:atom_fixture) { file_fixture("feeds/atom.xml").read }

  describe "RSS 2.0 success" do
    it "fetches, parses, and maps all feed and entry fields with metadata" do
      stub_request(:get, "http://example.com/rss.xml")
        .with(headers: {
          "User-Agent" => Feeds::Fetcher::USER_AGENT,
          "Accept" => Feeds::Fetcher::ACCEPT_HEADER
        })
        .to_return(
          status: 200,
          body: rss_fixture,
          headers: {
            "ETag" => '"etag-rss-123"',
            "Last-Modified" => "Mon, 01 Jan 2024 12:00:00 GMT"
          }
        )

      result = described_class.call("http://example.com/rss.xml", resolver: fake_resolver)

      expect(result.ok?).to be true
      expect(result.error).to be_nil
      expect(result.message).to be_nil
      expect(result.status).to eq(200)
      expect(result.final_url).to eq("http://example.com/rss.xml")
      expect(result.etag).to eq('"etag-rss-123"')
      expect(result.last_modified).to eq("Mon, 01 Jan 2024 12:00:00 GMT")

      feed = result.feed
      expect(feed.title).to eq("Cerrynt RSS Feed")
      expect(feed.site_url).to eq("https://example.com/rss")
      expect(feed.entries.size).to eq(2)

      entry1 = feed.entries.first
      expect(entry1.guid).to eq("item-1-guid")
      expect(entry1.url).to eq("https://example.com/items/1")
      expect(entry1.title).to eq("First RSS Item")
      expect(entry1.author).to eq("author@example.com (Alice)")
      expect(entry1.summary).to eq("Summary of first item")
      expect(entry1.content).to eq("<p>Full content of first item</p>")
      expect(entry1.published_at).to eq(Time.utc(2024, 1, 1, 12, 0, 0))

      entry2 = feed.entries.last
      expect(entry2.guid).to eq("item-2-guid")
      expect(entry2.summary).to eq("Summary of second item")
      expect(entry2.content).to be_nil
    end
  end

  describe "Atom success" do
    it "fetches, parses, and maps all Atom feed and entry fields" do
      stub_request(:get, "https://example.com/atom.xml")
        .to_return(
          status: 200,
          body: atom_fixture,
          headers: {
            "ETag" => '"atom-etag"',
            "Last-Modified" => "Mon, 01 Jan 2024 12:00:00 GMT"
          }
        )

      result = described_class.call("https://example.com/atom.xml", resolver: fake_resolver)

      expect(result.ok?).to be true
      expect(result.status).to eq(200)
      expect(result.final_url).to eq("https://example.com/atom.xml")
      expect(result.etag).to eq('"atom-etag"')
      expect(result.last_modified).to eq("Mon, 01 Jan 2024 12:00:00 GMT")

      feed = result.feed
      expect(feed.title).to eq("Cerrynt Atom Feed")
      expect(feed.site_url).to eq("https://example.com/atom")
      expect(feed.entries.size).to eq(1)

      entry = feed.entries.first
      expect(entry.guid).to eq("urn:uuid:1225c695-cfb8-4ebb-aaaa-80da344efa6a")
      expect(entry.url).to eq("https://example.com/atom/1")
      expect(entry.title).to eq("First Atom Entry")
      expect(entry.author).to eq("Alice")
      expect(entry.summary).to eq("Atom summary of first entry")
      expect(entry.content).to eq("<p>Full HTML content of first entry</p>")
      expect(entry.published_at).to eq(Time.utc(2024, 1, 1, 12, 0, 0))
    end
  end

  describe "URL validation (before network and resolver)" do
    let(:spy_resolver) { double("resolver") }

    def expect_invalid_url(url)
      result = described_class.call(url, resolver: spy_resolver)
      expect(result.ok?).to be false
      expect(result.error).to eq(:invalid_url)
      expect(result.message).to eq("Invalid feed URL")
      expect(result.status).to be_nil
      expect(result.feed).to be_nil
    end

    it "rejects nil and non-string inputs" do
      expect_invalid_url(nil)
      expect_invalid_url(12345)
    end

    it "rejects URLs longer than 2048 characters" do
      long_url = "http://example.com/" + ("a" * 2050)
      expect_invalid_url(long_url)
    end

    it "rejects non-http and non-https schemes" do
      expect_invalid_url("ftp://example.com/feed.xml")
      expect_invalid_url("file:///etc/passwd")
      expect_invalid_url("javascript:alert(1)")
      expect_invalid_url("gopher://example.com/feed")
    end

    it "rejects URLs missing a host" do
      expect_invalid_url("http:///path/only")
      expect_invalid_url("http://")
    end

    it "rejects URLs containing userinfo" do
      expect_invalid_url("http://user:pass@example.com/feed")
      expect_invalid_url("http://user@example.com/feed")
    end

    it "rejects ports other than 80 and 443" do
      expect_invalid_url("http://example.com:8080/feed")
      expect_invalid_url("https://example.com:8443/feed")
      expect_invalid_url("http://example.com:21/feed")
    end

    it "accepts explicit ports 80 and 443" do
      stub_request(:get, "http://example.com:80/feed").to_return(body: rss_fixture)
      stub_request(:get, "https://example.com:443/feed").to_return(body: rss_fixture)

      res80 = described_class.call("http://example.com:80/feed", resolver: fake_resolver)
      res443 = described_class.call("https://example.com:443/feed", resolver: fake_resolver)

      expect(res80.ok?).to be true
      expect(res443.ok?).to be true
    end

    it "rejects syntactically invalid URIs" do
      expect_invalid_url("http://exa mple.com/feed")
      expect_invalid_url("http://[invalid:ipv6]/feed")
    end
  end

  describe "SSRF protection with table-driven blocked addresses" do
    blocked_addresses = [
      # Loopback
      "127.0.0.1",
      "127.0.0.2",
      # Private RFC 1918
      "10.0.0.1",
      "172.16.0.1",
      "172.31.255.255",
      "192.168.1.1",
      # Link-local (including AWS metadata)
      "169.254.169.254",
      "169.254.1.1",
      # Carrier-grade NAT
      "100.64.0.1",
      "100.127.255.255",
      # 0.0.0.0/8
      "0.0.0.0",
      "0.0.0.1",
      # Multicast
      "224.0.0.1",
      "239.255.255.255",
      # Broadcast and reserved 240.0.0.0/4
      "240.0.0.1",
      "255.255.255.255",
      # Documentation ranges
      "192.0.2.1",
      "198.51.100.1",
      "203.0.113.1",
      # Benchmarking
      "198.18.0.1",
      # IETF protocol
      "192.0.0.1",
      # IPv6 loopback and unspecified
      "::1",
      "::",
      # IPv6 ULA
      "fc00::1",
      "fd12:3456::1",
      # IPv6 site-local unicast (deprecated RFC 3879)
      "fec0::1",
      # IPv6 discard prefix (RFC 6666)
      "100::1",
      # IPv6 TEREDO prefix (RFC 4380)
      "2001::1",
      # IPv6 documentation (RFC 3849)
      "2001:db8::1",
      # IPv4-compatible IPv6 (deprecated RFC 4291)
      "::192.168.1.1",
      # IPv6 Link-local and multicast
      "fe80::1",
      "ff02::1",
      # IPv4-mapped IPv6 with blocked embedded
      "::ffff:127.0.0.1",
      "::ffff:10.0.0.1",
      "::ffff:169.254.169.254",
      # NAT64 with blocked embedded
      "64:ff9b::127.0.0.1",
      "64:ff9b::192.168.1.1",
      # 6to4 with blocked embedded
      "2002:7f00:0001::",
      "2002:0a00:0001::"
    ]

    blocked_addresses.each do |blocked_ip|
      it "blocks connection when host resolves to #{blocked_ip}" do
        custom_resolver = ->(_host) { [ blocked_ip ] }
        result = described_class.call("http://test-host.example/feed", resolver: custom_resolver)

        expect(result.ok?).to be false
        expect(result.error).to eq(:blocked_address)
        expect(result.message).to eq("Address is not allowed")
      end
    end

    it "blocks a multi-homed host when any resolved address is blocked" do
      mixed_resolver = ->(_host) { [ "93.184.216.34", "10.0.0.1" ] }
      result = described_class.call("http://mixed-host.example/feed", resolver: mixed_resolver)

      expect(result.ok?).to be false
      expect(result.error).to eq(:blocked_address)
    end

    it "allows public IPv4 and IPv6 addresses" do
      stub_request(:get, "http://public-v4.example/feed").to_return(body: rss_fixture)
      stub_request(:get, "http://public-v6.example/feed").to_return(body: rss_fixture)
      stub_request(:get, "http://mapped-public.example/feed").to_return(body: rss_fixture)

      r4 = described_class.call("http://public-v4.example/feed", resolver: ->(_) { [ "93.184.216.34" ] })
      r6 = described_class.call("http://public-v6.example/feed", resolver: ->(_) { [ "2606:2800:220:1:248:1893:25c8:1946" ] })
      rm = described_class.call("http://mapped-public.example/feed", resolver: ->(_) { [ "::ffff:93.184.216.34" ] })

      expect(r4.ok?).to be true
      expect(r6.ok?).to be true
      expect(rm.ok?).to be true
    end
  end

  describe "Numeric IP literals (with REAL default resolver)" do
    numeric_hosts = [
      "2130706433",
      "0x7f.0.0.1",
      "127.1",
      "[::1]"
    ]

    numeric_hosts.each do |num_host|
      it "rejects #{num_host} via real resolver without DNS network traffic" do
        url = "http://#{num_host}/feed"
        result = described_class.call(url)

        expect(result.ok?).to be false
        expect(result.error).to eq(:blocked_address)
      end
    end
  end

  describe "Redirects" do
    it "follows up to 3 redirects to a final successful URL" do
      stub_request(:get, "http://example.com/r1")
        .to_return(status: 302, headers: { "Location" => "http://example.com/r2" })
      stub_request(:get, "http://example.com/r2")
        .to_return(status: 301, headers: { "Location" => "http://example.com/r3" })
      stub_request(:get, "http://example.com/r3")
        .to_return(status: 307, headers: { "Location" => "http://example.com/final.xml" })
      stub_request(:get, "http://example.com/final.xml")
        .to_return(status: 200, body: rss_fixture)

      result = described_class.call("http://example.com/r1", resolver: fake_resolver)

      expect(result.ok?).to be true
      expect(result.final_url).to eq("http://example.com/final.xml")
    end

    it "resolves relative Location headers against the current URL" do
      stub_request(:get, "http://example.com/path/feed")
        .to_return(status: 302, headers: { "Location" => "../atom.xml" })
      stub_request(:get, "http://example.com/atom.xml")
        .to_return(status: 200, body: atom_fixture)

      result = described_class.call("http://example.com/path/feed", resolver: fake_resolver)

      expect(result.ok?).to be true
      expect(result.final_url).to eq("http://example.com/atom.xml")
    end

    it "blocks redirect to a private address" do
      stub_request(:get, "http://example.com/redirect-to-private")
        .to_return(status: 302, headers: { "Location" => "http://internal.service.local/feed" })

      resolver = lambda do |host|
        host == "example.com" ? [ "93.184.216.34" ] : [ "10.0.0.1" ]
      end

      result = described_class.call("http://example.com/redirect-to-private", resolver: resolver)

      expect(result.ok?).to be false
      expect(result.error).to eq(:blocked_address)
    end

    it "fails on redirect loop or more than 3 redirects" do
      stub_request(:get, "http://example.com/loop1")
        .to_return(status: 302, headers: { "Location" => "http://example.com/loop2" })
      stub_request(:get, "http://example.com/loop2")
        .to_return(status: 302, headers: { "Location" => "http://example.com/loop3" })
      stub_request(:get, "http://example.com/loop3")
        .to_return(status: 302, headers: { "Location" => "http://example.com/loop4" })
      stub_request(:get, "http://example.com/loop4")
        .to_return(status: 302, headers: { "Location" => "http://example.com/loop5" })

      result = described_class.call("http://example.com/loop1", resolver: fake_resolver)

      expect(result.ok?).to be false
      expect(result.error).to eq(:too_many_redirects)
      expect(result.message).to eq("Too many redirects")
    end

    it "fails with :invalid_url if redirect Location is missing" do
      stub_request(:get, "http://example.com/missing-loc")
        .to_return(status: 302, headers: {})

      result = described_class.call("http://example.com/missing-loc", resolver: fake_resolver)

      expect(result.ok?).to be false
      expect(result.error).to eq(:invalid_url)
    end

    it "fails with :invalid_url if redirect target is not http/https" do
      stub_request(:get, "http://example.com/ftp-redirect")
        .to_return(status: 302, headers: { "Location" => "ftp://example.com/feed" })

      result = described_class.call("http://example.com/ftp-redirect", resolver: fake_resolver)

      expect(result.ok?).to be false
      expect(result.error).to eq(:invalid_url)
    end
  end

  describe "HTTP errors" do
    it "returns :http_error with status 404" do
      stub_request(:get, "http://example.com/not-found").to_return(status: 404)

      result = described_class.call("http://example.com/not-found", resolver: fake_resolver)

      expect(result.ok?).to be false
      expect(result.error).to eq(:http_error)
      expect(result.status).to eq(404)
    end

    it "returns :http_error with status 500" do
      stub_request(:get, "http://example.com/error").to_return(status: 500)

      result = described_class.call("http://example.com/error", resolver: fake_resolver)

      expect(result.ok?).to be false
      expect(result.error).to eq(:http_error)
      expect(result.status).to eq(500)
    end
  end

  describe "Body size limits (5 MB)" do
    it "rejects response with Content-Length greater than 5 MB before reading body" do
      stub_request(:get, "http://example.com/too-big-header")
        .to_return(
          status: 200,
          body: "small",
          headers: { "Content-Length" => (5 * 1024 * 1024 + 1).to_s }
        )

      result = described_class.call("http://example.com/too-big-header", resolver: fake_resolver)

      expect(result.ok?).to be false
      expect(result.error).to eq(:too_large)
      expect(result.message).to eq("Response body exceeded size limit")
    end

    it "aborts streaming when streamed body exceeds 5 MB without Content-Length" do
      oversized_body = "x" * (5 * 1024 * 1024 + 100)
      stub_request(:get, "http://example.com/too-big-stream")
        .to_return(status: 200, body: oversized_body)

      result = described_class.call("http://example.com/too-big-stream", resolver: fake_resolver)

      expect(result.ok?).to be false
      expect(result.error).to eq(:too_large)
    end
  end

  describe "Timeouts" do
    it "returns :timeout on connection or read timeout" do
      stub_request(:get, "http://example.com/slow").to_timeout

      result = described_class.call("http://example.com/slow", resolver: fake_resolver)

      expect(result.ok?).to be false
      expect(result.error).to eq(:timeout)
      expect(result.message).to eq("Request timed out")
    end

    it "returns :timeout when DNS resolution takes longer than DNS_TIMEOUT" do
      stub_const("Feeds::Fetcher::DNS_TIMEOUT", 0.02)
      slow_resolver = ->(_host) { sleep 0.05 }

      result = described_class.call("http://example.com/slow-dns", resolver: slow_resolver)

      expect(result.ok?).to be false
      expect(result.error).to eq(:timeout)
      expect(result.message).to eq("Request timed out")
    end

    it "returns :timeout when total elapsed time exceeds TOTAL_DEADLINE during a multi-redirect chain" do
      stub_request(:get, "http://example.com/r1")
        .to_return(status: 302, headers: { "Location" => "http://example.com/r2" })
      stub_request(:get, "http://example.com/r2")
        .to_return(body: rss_fixture)

      stub_const("Feeds::Fetcher::TOTAL_DEADLINE", 0.05)
      delayed_resolver = lambda do |_host|
        sleep 0.06
        [ public_ip ]
      end

      result = described_class.call("http://example.com/r1", resolver: delayed_resolver)

      expect(result.ok?).to be false
      expect(result.error).to eq(:timeout)
      expect(result.message).to eq("Request timed out")
    end
  end

  describe "Network and connection errors" do
    it "returns :unreachable when DNS resolver raises an error" do
      error_resolver = ->(_host) { raise Resolv::ResolvError, "DNS lookup failed" }

      result = described_class.call("http://example.com/feed", resolver: error_resolver)

      expect(result.ok?).to be false
      expect(result.error).to eq(:unreachable)
      expect(result.message).to eq("Could not connect to server")
    end

    it "returns :unreachable when DNS resolver returns an empty array" do
      empty_resolver = ->(_host) { [] }

      result = described_class.call("http://example.com/feed", resolver: empty_resolver)

      expect(result.ok?).to be false
      expect(result.error).to eq(:unreachable)
      expect(result.message).to eq("Could not connect to server")
    end

    it "returns :unreachable on SSL handshake failure" do
      stub_request(:get, "https://example.com/ssl-fail")
        .to_raise(OpenSSL::SSL::SSLError.new("SSL_connect error"))

      result = described_class.call("https://example.com/ssl-fail", resolver: fake_resolver)

      expect(result.ok?).to be false
      expect(result.error).to eq(:unreachable)
      expect(result.message).to eq("Could not connect to server")
    end

    it "returns :unreachable on connection refused" do
      stub_request(:get, "http://example.com/refused")
        .to_raise(Errno::ECONNREFUSED.new("Connection refused"))

      result = described_class.call("http://example.com/refused", resolver: fake_resolver)

      expect(result.ok?).to be false
      expect(result.error).to eq(:unreachable)
      expect(result.message).to eq("Could not connect to server")
    end
  end

  describe "Proxy bypass" do
    it "explicitly disables proxies so environment proxies are bypassed" do
      stub_request(:get, "http://example.com/feed").to_return(body: rss_fixture)

      expect(Net::HTTP).to receive(:new).with("example.com", 80, nil).and_call_original

      result = described_class.call("http://example.com/feed", resolver: fake_resolver)
      expect(result.ok?).to be true
    end
  end

  describe "Parsing and non-feed content" do
    it "returns :not_a_feed on empty body" do
      stub_request(:get, "http://example.com/empty").to_return(status: 200, body: "")

      result = described_class.call("http://example.com/empty", resolver: fake_resolver)

      expect(result.ok?).to be false
      expect(result.error).to eq(:not_a_feed)
      expect(result.message).to eq("Content is not a valid feed")
    end

    it "returns :not_a_feed on non-feed HTML" do
      stub_request(:get, "http://example.com/page.html")
        .to_return(status: 200, body: "<!DOCTYPE html><html><body><h1>Hello</h1></body></html>")

      result = described_class.call("http://example.com/page.html", resolver: fake_resolver)

      expect(result.ok?).to be false
      expect(result.error).to eq(:not_a_feed)
    end

    it "returns :not_a_feed on malformed XML garbage" do
      stub_request(:get, "http://example.com/garbage")
        .to_return(status: 200, body: "<random>not an rss or atom feed</random>")

      result = described_class.call("http://example.com/garbage", resolver: fake_resolver)

      expect(result.ok?).to be false
      expect(result.error).to eq(:not_a_feed)
    end
  end

  describe "Resolver invocations per hop" do
    it "calls the resolver exactly once for a single request" do
      call_count = 0
      resolver = lambda do |_host|
        call_count += 1
        [ public_ip ]
      end

      stub_request(:get, "http://example.com/single").to_return(body: rss_fixture)

      described_class.call("http://example.com/single", resolver: resolver)

      expect(call_count).to eq(1)
    end

    it "calls the resolver exactly once per hop across redirects" do
      call_count = 0
      resolver = lambda do |_host|
        call_count += 1
        [ public_ip ]
      end

      stub_request(:get, "http://example.com/h1")
        .to_return(status: 302, headers: { "Location" => "http://example.com/h2" })
      stub_request(:get, "http://example.com/h2")
        .to_return(body: rss_fixture)

      described_class.call("http://example.com/h1", resolver: resolver)

      expect(call_count).to eq(2)
    end
  end

  describe "Entry caps and fallback guid generation" do
    it "caps returned entries at 200" do
      items = (1..250).map do |i|
        "<item><title>Item #{i}</title><link>http://example.com/#{i}</link><guid>g-#{i}</guid></item>"
      end.join

      rss_large = "<rss version=\"2.0\"><channel><title>T</title><link>L</link>#{items}</channel></rss>"
      stub_request(:get, "http://example.com/many").to_return(body: rss_large)

      result = described_class.call("http://example.com/many", resolver: fake_resolver)

      expect(result.ok?).to be true
      expect(result.feed.entries.size).to eq(200)
    end

    it "falls back to entry url when guid is missing, and to sha256 hash when url is also missing" do
      feed_xml = <<~XML
        <rss version="2.0">
          <channel>
            <title>Test</title>
            <link>http://example.com</link>
            <item>
              <title>With URL only</title>
              <link>http://example.com/only-url</link>
            </item>
            <item>
              <title>No GUID No URL</title>
              <pubDate>Mon, 01 Jan 2024 12:00:00 GMT</pubDate>
            </item>
          </channel>
        </rss>
      XML

      stub_request(:get, "http://example.com/fallback-guids").to_return(body: feed_xml)

      result = described_class.call("http://example.com/fallback-guids", resolver: fake_resolver)

      expect(result.ok?).to be true
      entries = result.feed.entries

      # Fallback to URL
      expect(entries[0].guid).to eq("http://example.com/only-url")

      # Fallback to SHA256 of title + published
      expected_hash = Digest::SHA256.hexdigest("No GUID No URL2024-01-01 12:00:00 UTC")
      expect(entries[1].guid).to eq(expected_hash)
    end
  end

  describe "XML entity and DTD security" do
    let(:canary) { "CANARY_SECRET_DATA_TOKEN_12345" }
    let(:canary_file) do
      file = Tempfile.new("cerrynt_xxe_canary")
      file.write(canary)
      file.flush
      file
    end

    after do
      canary_file.close
      canary_file.unlink
    end

    it "rejects external general entity file disclosure and never leaks the canary" do
      xxe_payload = <<~XML
        <?xml version="1.0"?>
        <!DOCTYPE rss [
          <!ENTITY xxe SYSTEM "file://#{canary_file.path}">
        ]>
        <rss version="2.0">
          <channel>
            <title>&xxe;</title>
            <link>http://example.com</link>
            <description>&xxe;</description>
          </channel>
        </rss>
      XML

      stub_request(:get, "http://example.com/xxe-file").to_return(body: xxe_payload)

      result = described_class.call("http://example.com/xxe-file", resolver: fake_resolver)

      expect(result.ok?).to be false
      expect(result.error).to eq(:not_a_feed)
      expect(result.inspect).not_to include(canary)
    end

    it "rejects external parameter entity and never leaks the canary" do
      param_entity_payload = <<~XML
        <?xml version="1.0"?>
        <!DOCTYPE rss [
          <!ENTITY % pe SYSTEM "file://#{canary_file.path}">
          %pe;
        ]>
        <rss version="2.0">
          <channel>
            <title>Title</title>
            <link>http://example.com</link>
            <description>Description</description>
          </channel>
        </rss>
      XML

      stub_request(:get, "http://example.com/param-entity").to_return(body: param_entity_payload)

      result = described_class.call("http://example.com/param-entity", resolver: fake_resolver)

      expect(result.ok?).to be false
      expect(result.error).to eq(:not_a_feed)
      expect(result.inspect).not_to include(canary)
    end

    def with_loopback_listener
      server = TCPServer.new("127.0.0.1", 0)
      port = server.addr[1]
      reader, writer = IO.pipe

      pid = fork do
        reader.close
        conns = 0
        trap("TERM") do
          writer.write(conns.to_s)
          writer.close
          exit!(0)
        end
        loop do
          client = server.accept rescue break
          conns += 1
          client.write("HTTP/1.0 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n") rescue nil
          client.close rescue nil
        end
      end

      writer.close
      begin
        yield port
      ensure
        server.close rescue nil
        Process.kill("TERM", pid) rescue nil
        Process.wait(pid) rescue nil
      end

      reader.read.to_i
    end

    it "rejects external entity pointing to HTTP URL without libxml2 opening socket connections" do
      result = nil
      conns = with_loopback_listener do |port|
        xxe_http = <<~XML
          <?xml version="1.0"?>
          <!DOCTYPE rss [
            <!ENTITY ext SYSTEM "http://127.0.0.1:#{port}/secret">
          ]>
          <rss version="2.0">
            <channel>
              <title>&ext;</title>
              <link>http://example.com</link>
              <description>Test</description>
            </channel>
          </rss>
        XML

        stub_request(:get, "http://example.com/xxe-http").to_return(body: xxe_http)

        result = described_class.call("http://example.com/xxe-http", resolver: fake_resolver)
      end

      expect(conns).to eq(0)
      expect(result.ok?).to be false
      expect(result.error).to eq(:not_a_feed)
    end

    it "rejects external parameter entity pointing to HTTP URL without libxml2 opening socket connections" do
      result = nil
      conns = with_loopback_listener do |port|
        param_http = <<~XML
          <?xml version="1.0"?>
          <!DOCTYPE rss [
            <!ENTITY % pe SYSTEM "http://127.0.0.1:#{port}/pe">
            %pe;
          ]>
          <rss version="2.0">
            <channel>
              <title>Test</title>
              <link>http://example.com</link>
              <description>Test</description>
            </channel>
          </rss>
        XML

        stub_request(:get, "http://example.com/param-http").to_return(body: param_http)

        result = described_class.call("http://example.com/param-http", resolver: fake_resolver)
      end

      expect(conns).to eq(0)
      expect(result.ok?).to be false
      expect(result.error).to eq(:not_a_feed)
    end

    it "rejects internal DTD with external SYSTEM subset without libxml2 opening socket connections" do
      result = nil
      conns = with_loopback_listener do |port|
        external_dtd_payload = <<~XML
          <?xml version="1.0"?>
          <!DOCTYPE rss [
            <!ENTITY % dtd SYSTEM "http://127.0.0.1:#{port}/external.dtd">
            %dtd;
          ]>
          <rss version="2.0">
            <channel>
              <title>Test</title>
              <link>http://example.com</link>
              <description>Test</description>
            </channel>
          </rss>
        XML

        stub_request(:get, "http://example.com/external-dtd").to_return(body: external_dtd_payload)

        result = described_class.call("http://example.com/external-dtd", resolver: fake_resolver)
      end

      expect(conns).to eq(0)
      expect(result.ok?).to be false
      expect(result.error).to eq(:not_a_feed)
    end

    it "rejects billion-laughs payload with :not_a_feed within deadline" do
      billion_laughs = <<~XML
        <?xml version="1.0"?>
        <!DOCTYPE lolz [
         <!ENTITY lol "lol">
         <!ELEMENT lolz (#PCDATA)>
         <!ENTITY lol1 "&lol;&lol;&lol;&lol;&lol;&lol;&lol;&lol;&lol;&lol;">
         <!ENTITY lol2 "&lol1;&lol1;&lol1;&lol1;&lol1;&lol1;&lol1;&lol1;&lol1;&lol1;">
         <!ENTITY lol3 "&lol2;&lol2;&lol2;&lol2;&lol2;&lol2;&lol2;&lol2;&lol2;&lol2;">
        ]>
        <rss version="2.0">
          <channel>
            <title>&lol3;</title>
            <link>http://example.com</link>
            <description>&lol3;</description>
          </channel>
        </rss>
      XML

      stub_request(:get, "http://example.com/billion-laughs").to_return(body: billion_laughs)

      result = Timeout.timeout(2) do
        described_class.call("http://example.com/billion-laughs", resolver: fake_resolver)
      end

      expect(result.ok?).to be false
      expect(result.error).to eq(:not_a_feed)
    end

    it "parses legacy RSS 0.91 feed with DOCTYPE without internal subset normally" do
      rss_091 = <<~XML
        <?xml version="1.0"?>
        <!DOCTYPE rss PUBLIC "-//Netscape Communications//DTD RSS 0.91//EN" "http://my.netscape.com/publish/formats/rss-0.91.dtd">
        <rss version="0.91">
          <channel>
            <title>Netscape RSS 0.91 Feed</title>
            <link>http://example.com</link>
            <description>Legacy RSS Feed</description>
            <item>
              <title>Legacy Item</title>
              <link>http://example.com/item1</link>
            </item>
          </channel>
        </rss>
      XML

      stub_request(:get, "http://example.com/rss091").to_return(body: rss_091)

      result = described_class.call("http://example.com/rss091", resolver: fake_resolver)

      expect(result.ok?).to be true
      expect(result.feed.title).to eq("Netscape RSS 0.91 Feed")
      expect(result.feed.entries.size).to eq(1)
      assert_not_requested(:get, "http://my.netscape.com/publish/formats/rss-0.91.dtd")
    end

    it "continues to parse predefined XML entities normally" do
      predefined_entities_feed = <<~XML
        <?xml version="1.0"?>
        <rss version="2.0">
          <channel>
            <title>AT&amp;T &lt;Special&gt; &quot;Quotes&quot; &amp; &apos;Apostrophe&apos;</title>
            <link>http://example.com</link>
            <description>Predefined entities test</description>
            <item>
              <title>Fish &amp; Chips</title>
              <link>http://example.com/item</link>
            </item>
          </channel>
        </rss>
      XML

      stub_request(:get, "http://example.com/predefined-entities").to_return(body: predefined_entities_feed)

      result = described_class.call("http://example.com/predefined-entities", resolver: fake_resolver)

      expect(result.ok?).to be true
      expect(result.feed.title).to eq("AT&T <Special> \"Quotes\" & 'Apostrophe'")
    end

    it "successfully parses a benign feed encoded in UTF-16LE with BOM" do
      benign_xml = <<~XML
        <?xml version="1.0" encoding="utf-16"?>
        <rss version="2.0">
          <channel>
            <title>Benign UTF16 Feed</title>
            <link>http://example.com</link>
            <item>
              <title>Item 1</title>
              <link>http://example.com/1</link>
            </item>
          </channel>
        </rss>
      XML
      utf16_benign = "\xFF\xFE".b + benign_xml.encode("UTF-16LE").b

      stub_request(:get, "http://example.com/utf16-benign").to_return(body: utf16_benign)

      result = described_class.call("http://example.com/utf16-benign", resolver: fake_resolver)

      expect(result.ok?).to be true
      expect(result.feed.title).to eq("Benign UTF16 Feed")
      expect(result.feed.entries.size).to eq(1)
    end

    it "handles payload encoded in UTF-16LE with BOM without encoding error" do
      utf16_xxe = "\xFF\xFE".b + (<<~XML).encode("UTF-16LE").b
        <?xml version="1.0" encoding="utf-16"?>
        <!DOCTYPE rss [
          <!ENTITY xxe SYSTEM "file://#{canary_file.path}">
        ]>
        <rss version="2.0">
          <channel>
            <title>&xxe;</title>
            <link>http://example.com</link>
            <description>UTF16 XXE</description>
          </channel>
        </rss>
      XML

      stub_request(:get, "http://example.com/utf16-xxe").to_return(body: utf16_xxe)

      result = described_class.call("http://example.com/utf16-xxe", resolver: fake_resolver)

      expect(result.ok?).to be false
      expect(result.error).to eq(:not_a_feed)
      expect(result.inspect).not_to include(canary)
    end

    it "returns :not_a_feed when XML body has no root element" do
      no_root_payload = "<!-- XML comment only, no root element -->"
      stub_request(:get, "http://example.com/no-root").to_return(body: no_root_payload)

      result = described_class.call("http://example.com/no-root", resolver: fake_resolver)

      expect(result.ok?).to be false
      expect(result.error).to eq(:not_a_feed)
    end
  end

  describe "deadline: option" do
    it "returns :timeout when short deadline is exceeded by a slow resolver" do
      slow_resolver = lambda { |_host|
        sleep 0.1
        [ public_ip ]
      }

      result = described_class.call("http://example.com/rss.xml", resolver: slow_resolver, deadline: 0.02)
      expect(result.ok?).to be false
      expect(result.error).to eq(:timeout)
    end

    it "caps a larger deadline at TOTAL_DEADLINE" do
      stub_const("Feeds::Fetcher::TOTAL_DEADLINE", 0.02)
      slow_resolver = lambda { |_host|
        sleep 0.1
        [ public_ip ]
      }

      result = described_class.call("http://example.com/rss.xml", resolver: slow_resolver, deadline: 999)
      expect(result.ok?).to be false
      expect(result.error).to eq(:timeout)
    end

    it "raises ArgumentError when deadline is non-numeric, zero, negative, or nil" do
      [ 0, -1, -0.5, nil, "5", :ten, [] ].each do |invalid_deadline|
        expect {
          described_class.call("http://example.com/rss.xml", resolver: fake_resolver, deadline: invalid_deadline)
        }.to raise_error(ArgumentError, /deadline must be a positive Numeric/)
      end
    end
  end
end
