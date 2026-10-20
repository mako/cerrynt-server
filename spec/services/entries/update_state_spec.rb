# frozen_string_literal: true

require "rails_helper"

RSpec.describe Entries::UpdateState do
  include ActiveSupport::Testing::TimeHelpers

  let(:user) { create(:user) }
  let(:other_user) { create(:user) }
  let(:feed) { create(:feed) }
  let(:entry) { create(:entry, feed: feed) }

  it "creates a state row on true, preserves original timestamps and updated_at on repeat, and keeps a tombstone row when cleared" do
    t1 = Time.utc(2026, 10, 10, 10, 0, 0)
    t2 = Time.utc(2026, 10, 10, 11, 0, 0)
    t3 = Time.utc(2026, 10, 10, 12, 0, 0)

    state = travel_to(t1) do
      described_class.call(user: user, entry_id: entry.id, read: true)
    end
    expect(state.read_at).to eq(t1)
    expect(state.starred_at).to be_nil
    expect(state.updated_at).to eq(t1)

    # Repeat read: true at t2 -> no-op, read_at and updated_at stay t1
    travel_to(t2) do
      described_class.call(user: user, entry_id: entry.id, read: true)
    end
    state.reload
    expect(state.read_at).to eq(t1)
    expect(state.updated_at).to eq(t1)

    # Clear read: false at t3 -> keeps row, read_at nil, updated_at bumped to t3
    travel_to(t3) do
      described_class.call(user: user, entry_id: entry.id, read: false)
    end
    state.reload
    expect(state.read_at).to be_nil
    expect(state.starred_at).to be_nil
    expect(state.updated_at).to eq(t3)
  end

  it "recovers from a first-write RecordNotUnique race by retrying against the newly created row" do
    t1 = Time.utc(2026, 10, 10, 10, 0, 0)
    t2 = Time.utc(2026, 10, 10, 11, 0, 0)

    # Another concurrent writer has inserted the row with starred_at = t1
    create(:entry_state, user: user, entry: entry, read_at: nil, starred_at: t1, created_at: t1, updated_at: t1)

    locked_relation = EntryState.lock
    calls = 0
    allow(EntryState).to receive(:lock).and_return(locked_relation)
    allow(locked_relation).to receive(:find_by).and_wrap_original do |original, *args|
      calls += 1
      calls == 1 ? nil : original.call(*args)
    end

    travel_to(t2) do
      described_class.call(user: user, entry_id: entry.id, read: true)
    end

    expect(calls).to eq(2)
    expect(EntryState.where(user_id: user.id, entry_id: entry.id).count).to eq(1)
    state = EntryState.find_by!(user_id: user.id, entry_id: entry.id)
    expect(state.read_at).to eq(t2)
    expect(state.starred_at).to eq(t1)
    expect(state.updated_at).to eq(t2)
  end
end
