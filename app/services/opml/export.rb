# frozen_string_literal: true

require "nokogiri"

module Opml
  class Export
    ILLEGAL_XML_CHARS_REGEX = /[\u0000-\u0008\u000B-\u000C\u000E-\u001F\u007F\uFFFE\uFFFF]/

    def self.call(user:)
      new(user: user).call
    end

    def initialize(user:)
      @user = user
    end

    def call
      subscriptions = @user.subscriptions.includes(:feed).order(created_at: :asc, id: :asc)

      builder = Nokogiri::XML::Builder.new(encoding: "UTF-8") do |xml|
        xml.opml(version: "2.0") do
          xml.head do
            xml.title "Cerrynt subscriptions"
          end

          xml.body do
            subscriptions.each do |subscription|
              feed = subscription.feed
              name = sanitize(subscription.custom_title) || sanitize(feed&.title) || sanitize(feed&.url)
              xml_url = sanitize(feed&.url)
              html_url = sanitize(feed&.site_url)

              attrs = {
                type: "rss",
                text: name,
                title: name,
                xmlUrl: xml_url
              }
              attrs[:htmlUrl] = html_url if html_url.present?

              xml.outline(attrs)
            end
          end
        end
      end

      builder.to_xml
    end

    private

    def sanitize(candidate)
      return nil if candidate.nil?

      cleaned = candidate.to_s.scrub("").gsub(ILLEGAL_XML_CHARS_REGEX, "").squish
      cleaned.presence
    end
  end
end
