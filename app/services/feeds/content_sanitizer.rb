# frozen_string_literal: true

require "uri"
require "set"

module Feeds
  class ContentSanitizer
    TAGS = %w[
      a abbr b blockquote br cite code dd del div dl dt em figcaption figure
      h1 h2 h3 h4 h5 h6 hr i img ins kbd li mark ol p pre q s samp small
      span strong sub sup table tbody td tfoot th thead time tr u ul
    ].to_set.freeze

    FIRST_PASS_ATTRIBUTES = %w[
      href title src alt width height colspan rowspan datetime rel
    ].to_set.freeze

    ALLOWED_ATTRIBUTES_PER_ELEMENT = {
      "a" => %w[href title rel].to_set,
      "img" => %w[src alt title width height].to_set,
      "td" => %w[colspan rowspan].to_set,
      "th" => %w[colspan rowspan].to_set,
      "time" => %w[datetime].to_set,
      "abbr" => %w[title].to_set
    }.freeze

    MAX_INPUT_CHARS = 200_000
    MAX_URL_LENGTH = 2048

    def self.call(html, base_url: nil)
      return nil if html.nil?

      cleaned = html.to_s.scrub.delete("\0")
      return nil if cleaned.blank?

      cleaned = cleaned[0, MAX_INPUT_CHARS] if cleaned.length > MAX_INPUT_CHARS

      first_pass = Rails::HTML5::SafeListSanitizer.new.sanitize(cleaned, tags: TAGS, attributes: FIRST_PASS_ATTRIBUTES)
      return nil if first_pass.blank?

      doc = Nokogiri::HTML5.fragment(first_pass)

      doc.search("*").each do |node|
        next unless node.parent

        unless TAGS.include?(node.name)
          node.replace(node.children)
          next
        end

        allowed_attrs = ALLOWED_ATTRIBUTES_PER_ELEMENT[node.name] || Set.new
        node.attribute_nodes.each do |attr_node|
          node.remove_attribute(attr_node.name) unless allowed_attrs.include?(attr_node.name)
        end

        case node.name
        when "img"
          if node.has_attribute?("width")
            node.remove_attribute("width") unless node["width"].match?(/\A\d{1,4}\z/)
          end
          if node.has_attribute?("height")
            node.remove_attribute("height") unless node["height"].match?(/\A\d{1,4}\z/)
          end

          if node.has_attribute?("src")
            valid_src = resolve_and_validate_url(node["src"], base_url, allowed_schemes: %w[http https])
            if valid_src
              node["src"] = valid_src
            else
              node.remove
            end
          else
            node.remove
          end
        when "a"
          if node.has_attribute?("href")
            valid_href = resolve_and_validate_url(node["href"], base_url, allowed_schemes: %w[http https mailto])
            if valid_href
              node["href"] = valid_href
              node["rel"] = "nofollow noopener noreferrer"
            else
              node.remove_attribute("href")
              node.remove_attribute("rel")
            end
          else
            node.remove_attribute("rel")
          end
        end
      end

      result = doc.to_html.strip
      result.blank? ? nil : result
    rescue StandardError => e
      Rails.logger.warn("[Feeds::ContentSanitizer] #{e.class}")
      nil
    end

    def self.resolve_and_validate_url(raw_url, base_url, allowed_schemes:)
      return nil if raw_url.nil?

      raw = raw_url.to_s.strip
      return nil if raw.empty? || raw.length > MAX_URL_LENGTH

      uri = begin
        URI.parse(raw)
      rescue URI::Error
        nil
      end
      return nil if uri.nil?

      if uri.scheme.nil?
        return nil unless valid_base_url?(base_url)

        uri = begin
          URI.join(base_url, raw)
        rescue URI::Error
          nil
        end
        return nil if uri.nil?
      end

      return nil if uri.to_s.length > MAX_URL_LENGTH

      scheme = uri.scheme&.downcase
      return nil unless allowed_schemes.include?(scheme)

      if %w[http https].include?(scheme)
        return nil if uri.host.blank?
        return nil if uri.respond_to?(:userinfo) && uri.userinfo.present?
        return nil if uri.respond_to?(:user) && uri.user.present?
      elsif scheme == "mailto"
        return nil unless uri.is_a?(URI::MailTo) && uri.to.present?
        return nil if uri.respond_to?(:userinfo) && uri.userinfo.present?
      end

      uri.to_s
    end

    def self.valid_base_url?(url)
      return false if url.blank? || url.length > MAX_URL_LENGTH

      uri = begin
        URI.parse(url.to_s.strip)
      rescue URI::Error
        nil
      end
      return false if uri.nil?

      %w[http https].include?(uri.scheme&.downcase) &&
        uri.host.present? &&
        (uri.respond_to?(:userinfo) ? uri.userinfo.blank? : true) &&
        (uri.respond_to?(:user) ? uri.user.blank? : true)
    end
  end
end
