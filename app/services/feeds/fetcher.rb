# frozen_string_literal: true

require "digest"
require "ipaddr"
require "net/http"
require "nokogiri"
require "openssl"
require "socket"
require "timeout"
require "uri"
require "feedjira"

module Feeds
  class Fetcher
    # Error code mappings to docs/API.md:
    # :invalid_url, :blocked_address, :not_a_feed -> invalid_feed_url
    # :unreachable, :timeout, :too_large, :too_many_redirects, :http_error -> feed_unreachable

    Result = Data.define(:success, :error, :message, :status, :final_url, :etag, :last_modified, :feed) do
      def ok?
        success
      end
    end

    ParsedFeed = Data.define(:title, :site_url, :entries)
    ParsedEntry = Data.define(:guid, :url, :title, :author, :summary, :content, :published_at)

    MAX_URL_LENGTH = 2048
    ALLOWED_PORTS = [ 80, 443 ].freeze
    MAX_REDIRECTS = 3
    OPEN_TIMEOUT = 5
    READ_TIMEOUT = 5
    TOTAL_DEADLINE = 10
    DNS_TIMEOUT = 2
    MAX_BODY_BYTES = 5 * 1024 * 1024 # 5 MB
    MAX_ENTRIES = 200

    USER_AGENT = "Cerrynt/1.0 (+https://github.com/mako/cerrynt-server)"
    ACCEPT_HEADER = "application/atom+xml, application/rss+xml, application/xml;q=0.9, text/xml;q=0.8, */*;q=0.5"

    IPV4_BLOCKED_RANGES = [
      IPAddr.new("0.0.0.0/8"),         # Current network (RFC 1122)
      IPAddr.new("10.0.0.0/8"),        # Private network (RFC 1918)
      IPAddr.new("100.64.0.0/10"),     # Carrier-grade NAT (RFC 6598)
      IPAddr.new("127.0.0.0/8"),       # Loopback (RFC 1122)
      IPAddr.new("169.254.0.0/16"),    # Link-local (RFC 3927, includes 169.254.169.254)
      IPAddr.new("172.16.0.0/12"),     # Private network (RFC 1918)
      IPAddr.new("192.0.0.0/24"),      # IETF Protocol Assignments (RFC 6890)
      IPAddr.new("192.0.2.0/24"),      # Documentation TEST-NET-1 (RFC 5737)
      IPAddr.new("192.168.0.0/16"),    # Private network (RFC 1918)
      IPAddr.new("198.18.0.0/15"),     # Benchmarking (RFC 2544)
      IPAddr.new("198.51.100.0/24"),   # Documentation TEST-NET-2 (RFC 5737)
      IPAddr.new("203.0.113.0/24"),    # Documentation TEST-NET-3 (RFC 5737)
      IPAddr.new("224.0.0.0/4"),       # Multicast (RFC 5771)
      IPAddr.new("240.0.0.0/4"),       # Reserved / future use (RFC 1112)
      IPAddr.new("255.255.255.255/32") # Limited broadcast (RFC 919)
    ].freeze

    IPV6_BLOCKED_RANGES = [
      IPAddr.new("::/128"),        # Unspecified address (RFC 4291)
      IPAddr.new("::1/128"),       # Loopback (RFC 4291)
      IPAddr.new("::/96"),         # IPv4-compatible IPv6, deprecated (RFC 4291)
      IPAddr.new("100::/64"),      # Discard prefix (RFC 6666)
      IPAddr.new("2001::/32"),     # TEREDO prefix (RFC 4380)
      IPAddr.new("2001:db8::/32"), # Documentation (RFC 3849)
      IPAddr.new("fc00::/7"),      # Unique Local Address ULA (RFC 4193)
      IPAddr.new("fec0::/10"),     # Site-local unicast, deprecated (RFC 3879)
      IPAddr.new("fe80::/10"),     # Link-local unicast (RFC 4291)
      IPAddr.new("ff00::/8")       # Multicast (RFC 4291)
    ].freeze

    IPV4_MAPPED_IPV6_PREFIX = IPAddr.new("::ffff:0:0/96")
    NAT64_PREFIX = IPAddr.new("64:ff9b::/96")
    SIX_TO_FOUR_PREFIX = IPAddr.new("2002::/16")

    # Default DNS resolver uses system getaddrinfo bounded by DNS_TIMEOUT (2s).
    # 2s is chosen because normal DNS resolutions resolve in 10-50ms; giving 2s
    # accommodates slow authoritative nameservers while preserving at least 8s
    # for connection establishment and body streaming within the TOTAL_DEADLINE.
    DEFAULT_RESOLVER = ->(host) {
      clean_host = host.to_s.delete_prefix("[").delete_suffix("]")
      Timeout.timeout(DNS_TIMEOUT) do
        Addrinfo.getaddrinfo(clean_host, nil, nil, :STREAM).map(&:ip_address).uniq
      end
    }

    def self.call(url, resolver: DEFAULT_RESOLVER, deadline: TOTAL_DEADLINE)
      new(url, resolver: resolver, deadline: deadline).call
    end

    def self.blocked_address?(ip_or_str)
      ip = ip_or_str.is_a?(IPAddr) ? ip_or_str : IPAddr.new(ip_or_str.to_s)
      if ip.ipv4?
        IPV4_BLOCKED_RANGES.any? { |range| range.include?(ip) }
      elsif ip.ipv6?
        embedded_ipv4 = extract_embedded_ipv4(ip)
        if embedded_ipv4
          IPV4_BLOCKED_RANGES.any? { |range| range.include?(embedded_ipv4) }
        else
          IPV6_BLOCKED_RANGES.any? { |range| range.include?(ip) }
        end
      else
        true
      end
    rescue IPAddr::InvalidAddressError
      true
    end

    def self.extract_embedded_ipv4(ip)
      return nil unless ip.ipv6?

      if IPV4_MAPPED_IPV6_PREFIX.include?(ip) || NAT64_PREFIX.include?(ip)
        ipv4_int = ip.to_i & 0xffffffff
        IPAddr.new(ipv4_int, Socket::AF_INET)
      elsif SIX_TO_FOUR_PREFIX.include?(ip)
        ipv4_int = (ip.to_i >> 80) & 0xffffffff
        IPAddr.new(ipv4_int, Socket::AF_INET)
      end
    rescue IPAddr::InvalidAddressError
      nil
    end

    def self.success(final_url:, etag:, last_modified:, feed:, status: 200)
      Result.new(
        success: true,
        error: nil,
        message: nil,
        status: status,
        final_url: final_url,
        etag: etag,
        last_modified: last_modified,
        feed: feed
      )
    end

    def self.failure(error, message: default_message_for(error), status: nil, final_url: nil)
      Result.new(
        success: false,
        error: error,
        message: message,
        status: status,
        final_url: final_url,
        etag: nil,
        last_modified: nil,
        feed: nil
      )
    end

    def self.default_message_for(error)
      case error
      when :invalid_url then "Invalid feed URL"
      when :blocked_address then "Address is not allowed"
      when :unreachable then "Could not connect to server"
      when :timeout then "Request timed out"
      when :too_large then "Response body exceeded size limit"
      when :too_many_redirects then "Too many redirects"
      when :http_error then "HTTP request failed"
      when :not_a_feed then "Content is not a valid feed"
      else "Failed to fetch feed"
      end
    end

    def initialize(url, resolver: DEFAULT_RESOLVER, deadline: TOTAL_DEADLINE)
      unless deadline.is_a?(Numeric) && deadline.positive?
        raise ArgumentError, "deadline must be a positive Numeric, got: #{deadline.inspect}"
      end

      @initial_url = url
      @resolver = resolver
      @deadline = [ deadline, TOTAL_DEADLINE ].min
    end

    def call
      deadline_end = Process.clock_gettime(Process::CLOCK_MONOTONIC) + @deadline
      current_url = @initial_url
      redirect_count = 0

      loop do
        remaining_time = deadline_end - Process.clock_gettime(Process::CLOCK_MONOTONIC)
        return failure(:timeout, final_url: current_url) if remaining_time <= 0

        uri = validate_url(current_url)
        return failure(:invalid_url, final_url: current_url) unless uri

        addresses = resolve(uri.host, remaining_time)
        return addresses if addresses.is_a?(Result)
        return failure(:unreachable, final_url: current_url) if addresses.empty?

        if addresses.any? { |addr| self.class.blocked_address?(addr) }
          return failure(:blocked_address, final_url: current_url)
        end

        chosen_ip = addresses.first.to_s

        remaining_time = deadline_end - Process.clock_gettime(Process::CLOCK_MONOTONIC)
        return failure(:timeout, final_url: current_url) if remaining_time <= 0

        response, body = fetch_http(uri, chosen_ip, remaining_time)
        return response if response.is_a?(Result)

        if response.is_a?(Net::HTTPRedirection)
          redirect_count += 1
          if redirect_count > MAX_REDIRECTS
            return failure(:too_many_redirects, final_url: current_url)
          end

          location = response["location"]
          if location.nil? || location.strip.empty?
            return failure(:invalid_url, final_url: current_url)
          end

          begin
            next_uri = URI.join(current_url, location)
            unless next_uri.is_a?(URI::HTTP) || next_uri.is_a?(URI::HTTPS)
              return failure(:invalid_url, final_url: current_url)
            end
            current_url = next_uri.to_s
          rescue URI::InvalidURIError
            return failure(:invalid_url, final_url: current_url)
          end

          next
        end

        status_code = response.code.to_i
        if status_code >= 400
          return failure(:http_error, status: status_code, final_url: current_url)
        end

        unless response.is_a?(Net::HTTPSuccess)
          return failure(:http_error, status: status_code, final_url: current_url)
        end

        return parse_feed(body, response: response, final_url: current_url)
      end
    rescue Timeout::Error
      failure(:timeout, final_url: current_url)
    rescue StandardError => e
      Rails.logger.warn("[Feeds::Fetcher] #{e.class}")
      failure(:unreachable, final_url: current_url)
    end

    private

    def validate_url(url)
      return nil if url.nil? || !url.is_a?(String)
      return nil if url.length > MAX_URL_LENGTH

      uri = URI.parse(url)
      return nil unless uri.is_a?(URI::HTTP) || uri.is_a?(URI::HTTPS)
      return nil if uri.host.nil? || uri.host.strip.empty?
      return nil if uri.user || uri.password
      return nil unless ALLOWED_PORTS.include?(uri.port)

      uri
    rescue URI::InvalidURIError
      nil
    end

    def resolve(host, remaining_time)
      timeout_duration = [ DNS_TIMEOUT, remaining_time ].min
      return failure(:timeout) if timeout_duration <= 0

      Timeout.timeout(timeout_duration) do
        Array(@resolver.call(host))
      end
    rescue Timeout::Error
      failure(:timeout)
    rescue StandardError
      failure(:unreachable)
    end

    def fetch_http(uri, ip, remaining_time)
      http = Net::HTTP.new(uri.host, uri.port, nil)
      http.ipaddr = ip
      http.open_timeout = [ OPEN_TIMEOUT, remaining_time ].min
      http.read_timeout = [ READ_TIMEOUT, remaining_time ].min
      if uri.scheme == "https"
        http.use_ssl = true
        http.verify_mode = OpenSSL::SSL::VERIFY_PEER
      end

      req = Net::HTTP::Get.new(uri.request_uri)
      req["User-Agent"] = USER_AGENT
      req["Accept"] = ACCEPT_HEADER

      response = nil
      body = nil

      too_large = catch(:too_large) do
        Timeout.timeout(remaining_time) do
          http.request(req) do |res|
            response = res
            return [ response, nil ] if response.is_a?(Net::HTTPRedirection)

            content_length = response["content-length"]
            if content_length.present? && content_length.to_i > MAX_BODY_BYTES
              throw :too_large, true
            end

            total_bytes = 0
            chunks = []
            response.read_body do |chunk|
              total_bytes += chunk.bytesize
              throw :too_large, true if total_bytes > MAX_BODY_BYTES
              chunks << chunk
            end
            body = chunks.join
          end
        end
        false
      end

      return [ failure(:too_large, final_url: uri.to_s), nil ] if too_large

      [ response, body ]
    rescue Timeout::Error, Net::OpenTimeout, Net::ReadTimeout
      [ failure(:timeout, final_url: uri.to_s), nil ]
    rescue StandardError
      [ failure(:unreachable, final_url: uri.to_s), nil ]
    end

    def parse_feed(body, response:, final_url:)
      status_code = response.code.to_i
      return failure(:not_a_feed, status: status_code, final_url: final_url) if body.blank?

      # Feedjira's SAX handler resolves external entities, so documents with DTD
      # declarations are rejected before Feedjira sees them. This Nokogiri pre-check
      # is the only XXE defense; removing it requires the XML security specs to stay green.
      doc = begin
        Nokogiri::XML(body) do |config|
          config.default_xml.nonet
        end
      rescue StandardError
        nil
      end

      return failure(:not_a_feed, status: status_code, final_url: final_url) if doc.nil? || doc.root.nil?
      return failure(:not_a_feed, status: status_code, final_url: final_url) if doc.internal_subset&.children&.any?

      parsed = begin
        Feedjira.parse(body)
      rescue StandardError
        begin
          Feedjira.parse(doc.to_xml(encoding: "UTF-8"))
        rescue StandardError
          nil
        end
      end

      if parsed.nil? || !parsed.respond_to?(:entries) || parsed.entries.nil?
        return failure(:not_a_feed, status: status_code, final_url: final_url)
      end

      entries = parsed.entries.first(MAX_ENTRIES).map do |entry|
        guid = if entry.respond_to?(:entry_id) && entry.entry_id.present?
                 entry.entry_id
        elsif entry.respond_to?(:url) && entry.url.present?
                 entry.url
        else
          title = entry.respond_to?(:title) ? entry.title.to_s : ""
          published = entry.respond_to?(:published) ? entry.published.to_s : ""
          Digest::SHA256.hexdigest("#{title}#{published}")
        end

        ParsedEntry.new(
          guid: guid,
          url: entry.respond_to?(:url) ? entry.url : nil,
          title: entry.respond_to?(:title) ? entry.title : nil,
          author: entry.respond_to?(:author) ? entry.author : nil,
          summary: entry.respond_to?(:summary) ? entry.summary : nil,
          content: entry.respond_to?(:content) ? entry.content : nil,
          published_at: entry.respond_to?(:published) ? entry.published : nil
        )
      end

      feed = ParsedFeed.new(
        title: parsed.respond_to?(:title) ? parsed.title : nil,
        site_url: parsed.respond_to?(:url) ? parsed.url : nil,
        entries: entries
      )

      self.class.success(
        final_url: final_url,
        etag: response["etag"],
        last_modified: response["last-modified"],
        feed: feed,
        status: status_code
      )
    end

    def failure(error, message: self.class.default_message_for(error), status: nil, final_url: nil)
      self.class.failure(error, message: message, status: status, final_url: final_url)
    end
  end
end
