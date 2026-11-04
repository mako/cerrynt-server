# frozen_string_literal: true

require "uri"

module Feeds
  module UrlPolicy
    MAX_URL_LENGTH = 2048
    ALLOWED_PORTS = [ 80, 443 ].freeze

    def self.validate_feed_url(url)
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

    def self.normalize_feed_url(url)
      Feed.normalize_value_for(:url, url)
    end

    def self.normalize_and_validate_feed_url(url)
      return nil if url.nil? || !url.is_a?(String) || url.length > MAX_URL_LENGTH
      return nil unless validate_feed_url(url)

      normalized = normalize_feed_url(url)
      return nil if normalized.blank? || normalized.length > MAX_URL_LENGTH
      return nil unless validate_feed_url(normalized)

      normalized
    end

    def self.valid_site_url?(url)
      return false if url.blank? || !url.is_a?(String)
      return false if url.length > MAX_URL_LENGTH

      uri = URI.parse(url.strip)
      (uri.is_a?(URI::HTTP) || uri.is_a?(URI::HTTPS)) &&
        uri.host.present? &&
        uri.userinfo.blank? &&
        uri.user.blank? &&
        uri.password.blank?
    rescue URI::InvalidURIError
      false
    end

    def self.clean_site_url(url)
      return nil unless valid_site_url?(url)

      url.to_s.strip
    end
  end
end
