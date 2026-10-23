# frozen_string_literal: true

require "nokogiri"

module Xml
  class SafeParser
    Result = Data.define(:success, :doc, :error) do
      def ok?
        success
      end
    end

    def self.parse(body, doctype: :reject)
      new(body, doctype: doctype).parse
    end

    def initialize(body, doctype: :reject)
      @body = body
      @doctype = doctype
    end

    def parse
      return failure(:malformed) if @body.nil? || @body.bytesize.zero? || @body.to_s.scrub.strip.empty?

      doc = begin
        Nokogiri::XML(@body) do |config|
          config.default_xml.nonet
        end
      rescue StandardError
        nil
      end

      return failure(:malformed) if doc.nil? || doc.root.nil?

      case @doctype
      when :reject
        if doc_has_doctype?(doc)
          return failure(:doctype_not_allowed)
        end

        if doc.errors.any?(&:fatal?)
          return failure(:malformed)
        end
      # Feedjira's SAX handler resolves external entities, so documents with DTD
      # declarations must be rejected before Feedjira sees them; this Nokogiri pre-check
      # is the XXE defense; removing it requires the XML security specs to stay green.
      when :fetcher_compatible
        if doc.internal_subset&.children&.any?
          return failure(:doctype_not_allowed)
        end
      else
        raise ArgumentError, "Unknown doctype policy: #{@doctype.inspect}"
      end

      success(doc)
    end

    private

    def doc_has_doctype?(doc)
      doc.internal_subset.present? ||
        doc.external_subset.present? ||
        doc.children.any? { |node| node.type == Nokogiri::XML::Node::DTD_NODE }
    end

    def success(doc)
      Result.new(success: true, doc: doc, error: nil)
    end

    def failure(error)
      Result.new(success: false, doc: nil, error: error)
    end
  end
end
