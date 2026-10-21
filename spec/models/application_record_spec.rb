# frozen_string_literal: true

require "rails_helper"

RSpec.describe ApplicationRecord, type: :model do
  describe ".write_transaction" do
    it "materializes the transaction before reading Time.current and yielding it" do
      events = []
      materialized_when_time_read = nil

      sub = ActiveSupport::Notifications.subscribe("sql.active_record") do |_name, _start, _finish, _id, payload|
        sql = payload[:sql].to_s.strip
        events << :begin if sql.match?(/\A(BEGIN|SAVEPOINT)\b/i)
      end

      allow(Time).to receive(:current).and_wrap_original do |original|
        materialized_when_time_read = described_class.connection.current_transaction.materialized?
        events << :time_current
        original.call
      end

      yielded_time = nil
      materialized_inside_block = nil

      begin
        described_class.write_transaction do |now|
          yielded_time = now
          materialized_inside_block = described_class.connection.current_transaction.materialized?
        end
      ensure
        ActiveSupport::Notifications.unsubscribe(sub)
      end

      expect(yielded_time).to be_a(ActiveSupport::TimeWithZone)
      expect(materialized_when_time_read).to be(true)
      expect(materialized_inside_block).to be(true)
      expect(events.index(:begin)).not_to be_nil
      expect(events.index(:time_current)).to be > events.index(:begin)
    end
  end
end
