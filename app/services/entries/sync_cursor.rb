# frozen_string_literal: true

require "base64"
require "date"
require "json"

module Entries
  class SyncCursor
    MAX_LENGTH = 256
    MAX_ID = (1 << 63) - 1
    BASE64URL_REGEX = /\A[A-Za-z0-9_-]+\z/
    TIMESTAMP_REGEX = /\A(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})\.(\d{6})Z\z/
    EXPECTED_KEYS = %w[changed_at id].freeze

    class << self
      def encode(changed_at:, id:)
        payload = {
          changed_at: changed_at.utc.iso8601(6),
          id: id
        }
        Base64.urlsafe_encode64(JSON.generate(payload), padding: false)
      end

      def decode(str)
        return nil unless str.is_a?(String)
        return nil if str.empty? || str.length > MAX_LENGTH
        return nil unless str.match?(BASE64URL_REGEX)

        decoded = Base64.urlsafe_decode64(str)
        return nil unless Base64.urlsafe_encode64(decoded, padding: false) == str

        payload = JSON.parse(decoded)
        return nil unless payload.is_a?(Hash) && payload.keys.sort == EXPECTED_KEYS

        id = payload["id"]
        return nil unless id.is_a?(Integer) && id >= 0 && id <= MAX_ID

        changed_at_str = payload["changed_at"]
        return nil unless changed_at_str.is_a?(String)

        match = TIMESTAMP_REGEX.match(changed_at_str)
        return nil unless match

        year = match[1].to_i
        month = match[2].to_i
        day = match[3].to_i
        hour = match[4].to_i
        min = match[5].to_i
        sec = match[6].to_i
        usec = match[7].to_i

        return nil unless Date.valid_date?(year, month, day)
        return nil unless hour <= 23 && min <= 59 && sec <= 59

        [ Time.utc(year, month, day, hour, min, sec, usec), id ]
      rescue ArgumentError, JSON::ParserError, EncodingError
        nil
      end
    end

    EPOCH = encode(changed_at: Time.at(0).utc, id: 0).freeze
  end
end
