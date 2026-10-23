# frozen_string_literal: true

module Opml
  class Parser
    MAX_BODY_BYTES = 1_048_576 # 1 MB
    MAX_FEED_OUTLINES = 500
    MAX_URL_LENGTH = 2048
    MAX_TITLE_LENGTH = 500

    CONTROL_CHARS_REGEX = /[\u0000-\u0008\u000B-\u000C\u000E-\u001F\u007F]/

    Result = Data.define(:success, :outlines, :error) do
      def ok?
        success
      end

      def reason
        error
      end
    end

    def self.parse(body)
      new(body).parse
    end

    def initialize(body)
      @body = body
    end

    def parse
      return failure(:malformed) unless @body.is_a?(String)
      return failure(:too_large) if @body.bytesize > MAX_BODY_BYTES
      return failure(:malformed) if @body.bytesize.zero? || @body.b.strip.empty?

      safe_result = Xml::SafeParser.parse(@body.b, doctype: :reject)
      return failure(safe_result.error) unless safe_result.ok?

      doc = safe_result.doc
      return failure(:malformed) if doc.nil? || doc.root.nil?
      return failure(:not_opml) unless doc.root.name.to_s.casecmp("opml").zero?

      feed_outlines = []

      doc.xpath("//outline").each do |node|
        attrs = node.attributes.transform_keys(&:downcase)
        raw_xml_url = attrs["xmlurl"]&.value
        clean_url = sanitize_url(raw_xml_url)
        next if clean_url.blank?

        if feed_outlines.size >= MAX_FEED_OUTLINES
          return failure(:too_many_outlines)
        end

        raw_title = attrs["title"]&.value.presence || attrs["text"]&.value.presence
        raw_html_url = attrs["htmlurl"]&.value.presence

        clean_title = sanitize_title(raw_title)
        clean_html_url = sanitize_html_url(raw_html_url)

        feed_outlines << {
          url: clean_url,
          title: clean_title,
          html_url: clean_html_url
        }
      end

      success(feed_outlines)
    end

    private

    def sanitize_url(str)
      return nil if str.nil?

      cleaned = str.to_s.scrub("").gsub(CONTROL_CHARS_REGEX, "").strip
      cleaned.presence
    end

    def sanitize_title(str)
      return nil if str.nil?

      cleaned = str.to_s.scrub("").gsub(CONTROL_CHARS_REGEX, "").strip
      return nil if cleaned.empty?

      cleaned[0, MAX_TITLE_LENGTH]
    end

    def sanitize_html_url(str)
      return nil if str.nil?

      cleaned = str.to_s.scrub("").gsub(CONTROL_CHARS_REGEX, "").strip
      return nil if cleaned.empty? || cleaned.length > MAX_URL_LENGTH

      cleaned
    end

    def success(outlines)
      Result.new(success: true, outlines: outlines, error: nil)
    end

    def failure(error)
      Result.new(success: false, outlines: nil, error: error)
    end
  end
end
