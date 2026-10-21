# frozen_string_literal: true

require "rails_helper"

RSpec.describe Entries::SyncCursor do
  describe ".encode and .decode" do
    it "round-trips timestamps with exact microseconds (.123456, .000001, .000000)" do
      [ 123_456, 1, 0, 999_999, 500_000 ].each do |usec|
        t = Time.utc(2026, 10, 21, 22, 4, 20, usec)
        encoded = described_class.encode(changed_at: t, id: 42)
        expect(encoded).to be_a(String)
        expect(encoded).not_to include("=")

        decoded_time, decoded_id = described_class.decode(encoded)
        expect(decoded_id).to eq(42)
        expect(decoded_time).to eq(t)
        expect(decoded_time.usec).to eq(usec)
        expect(decoded_time.utc?).to be(true)
      end
    end

    it "defines EPOCH as the encoded cursor for Time.at(0).utc and id 0, and decodes it back" do
      expect(described_class::EPOCH).to eq(described_class.encode(changed_at: Time.at(0).utc, id: 0))
      decoded_time, decoded_id = described_class.decode(described_class::EPOCH)
      expect(decoded_time).to eq(Time.at(0).utc)
      expect(decoded_time.usec).to eq(0)
      expect(decoded_id).to eq(0)
    end

    it "returns nil and never raises for malformed, tampered, or out-of-range inputs" do
      valid_cursor = described_class.encode(changed_at: Time.utc(2026, 10, 21, 12, 0, 0, 123_456), id: 7)
      b64 = ->(str) { Base64.urlsafe_encode64(str, padding: false) }

      invalid_inputs = [
        nil,
        "",
        123,
        true,
        [],
        {},
        "!!!not-base64!!!",
        "#{valid_cursor}=",
        "#{valid_cursor}\n",
        " #{valid_cursor}",
        "#{valid_cursor} ",
        # Non-canonical base64url (non-zero trailing bits)
        "e30B",
        b64.call("not-json"),
        b64.call('["2026-10-21T12:00:00.000000Z", 1]'),
        b64.call('{"changed_at":"2026-10-21T12:00:00.000000Z","id":1,"extra":true}'),
        b64.call('{"changed_at":"2026-10-21T12:00:00.000000Z"}'),
        b64.call('{"id":1}'),
        b64.call("{}"),
        b64.call('{"changed_at":"2026-10-21T12:00:00.000000Z","id":"1"}'),
        b64.call('{"changed_at":"2026-10-21T12:00:00.000000Z","id":1.5}'),
        b64.call('{"changed_at":"2026-10-21T12:00:00.000000Z","id":true}'),
        b64.call('{"changed_at":"2026-10-21T12:00:00.000000Z","id":null}'),
        b64.call('{"changed_at":"2026-10-21T12:00:00.000000Z","id":-1}'),
        b64.call("{\"changed_at\":\"2026-10-21T12:00:00.000000Z\",\"id\":#{(1 << 63)}}"),
        b64.call('{"changed_at":"2026-10-21T12:00:00Z","id":1}'),
        b64.call('{"changed_at":"2026-10-21T12:00:00.123Z","id":1}'),
        b64.call('{"changed_at":"2026-10-21T12:00:00.123456","id":1}'),
        b64.call('{"changed_at":"2026-10-21T12:00:00.123456+00:00","id":1}'),
        b64.call('{"changed_at":"2026-10-21T12:00:00.123456+02:00","id":1}'),
        b64.call('{"changed_at":"2026-02-30T12:00:00.000000Z","id":1}'),
        b64.call('{"changed_at":"2026-13-01T12:00:00.000000Z","id":1}'),
        b64.call('{"changed_at":"2026-10-21T24:00:00.000000Z","id":1}'),
        b64.call('{"changed_at":null,"id":1}'),
        "a" * 257
      ]

      invalid_inputs.each do |bad|
        expect {
          expect(described_class.decode(bad)).to be_nil, "Expected nil for #{bad.inspect}"
        }.not_to raise_error
      end
    end
  end
end
