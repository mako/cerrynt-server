# frozen_string_literal: true

require "rails_helper"

RSpec.describe Entries::MarkRead do
  include ActiveSupport::Testing::TimeHelpers

  let(:user) { create(:user, plan: "pro") }
  let(:other_user) { create(:user, plan: "pro") }
  let(:feed_a) { create(:feed) }
  let(:feed_b) { create(:feed) }
  let(:unfollowed_feed) { create(:feed) }
  let!(:sub_a) { create(:subscription, user: user, feed: feed_a) }
  let!(:sub_b) { create(:subscription, user: user, feed: feed_b) }
  let!(:other_sub_a) { create(:subscription, user: other_user, feed: feed_a) }
  let!(:other_sub_unfollowed) { create(:subscription, user: other_user, feed: unfollowed_feed) }

  it "marks missing-state, unread-state, and starred-only rows, leaves already-read and other users' rows untouched, and is idempotent" do
    t_pub = Time.utc(2026, 10, 1, 12, 0, 0)
    t_initial = Time.utc(2026, 10, 5, 10, 0, 0)
    t_mark = Time.utc(2026, 10, 10, 15, 0, 0)
    t_second = Time.utc(2026, 10, 10, 16, 0, 0)

    e_no_state = create(:entry, feed: feed_a, published_at: t_pub)
    e_unread_row = create(:entry, feed: feed_a, published_at: t_pub)
    e_starred_only = create(:entry, feed: feed_b, published_at: t_pub)
    e_already_read = create(:entry, feed: feed_b, published_at: t_pub)
    e_unfollowed = create(:entry, feed: unfollowed_feed, published_at: t_pub)

    s_unread = create(:entry_state, user: user, entry: e_unread_row, read_at: nil, starred_at: nil, created_at: t_initial, updated_at: t_initial)
    s_starred = create(:entry_state, user: user, entry: e_starred_only, read_at: nil, starred_at: t_initial, created_at: t_initial, updated_at: t_initial)
    s_read = create(:entry_state, user: user, entry: e_already_read, read_at: t_initial, starred_at: nil, created_at: t_initial, updated_at: t_initial)
    s_other_unread = create(:entry_state, user: other_user, entry: e_unread_row, read_at: nil, starred_at: t_initial, created_at: t_initial, updated_at: t_initial)

    marked = travel_to(t_mark) do
      described_class.call(user: user, before: t_pub)
    end
    expect(marked).to eq(3)

    # Entry without state row got a new row with read_at = now
    s_created = EntryState.find_by!(user_id: user.id, entry_id: e_no_state.id)
    expect(s_created.read_at).to eq(t_mark)
    expect(s_created.starred_at).to be_nil
    expect(s_created.created_at).to eq(t_mark)
    expect(s_created.updated_at).to eq(t_mark)

    # Existing unread row updated with read_at = now and updated_at = now
    s_unread.reload
    expect(s_unread.read_at).to eq(t_mark)
    expect(s_unread.starred_at).to be_nil
    expect(s_unread.updated_at).to eq(t_mark)

    # Starred-only row gets read_at = now, keeps starred_at = t_initial, bumps updated_at = now
    s_starred.reload
    expect(s_starred.read_at).to eq(t_mark)
    expect(s_starred.starred_at).to eq(t_initial)
    expect(s_starred.updated_at).to eq(t_mark)

    # Already-read row keeps original read_at and updated_at
    s_read.reload
    expect(s_read.read_at).to eq(t_initial)
    expect(s_read.updated_at).to eq(t_initial)

    # Unfollowed feed entry has no state row for user
    expect(EntryState.exists?(user_id: user.id, entry_id: e_unfollowed.id)).to be(false)

    # Other user's state rows and count untouched
    s_other_unread.reload
    expect(s_other_unread.read_at).to be_nil
    expect(s_other_unread.starred_at).to eq(t_initial)
    expect(s_other_unread.updated_at).to eq(t_initial)
    expect(EntryState.where(user_id: other_user.id).count).to eq(1)

    # Second identical call returns 0 and leaves timestamps unchanged
    marked_again = travel_to(t_second) do
      described_class.call(user: user, before: t_pub)
    end
    expect(marked_again).to eq(0)
    expect(s_created.reload.updated_at).to eq(t_mark)
    expect(s_unread.reload.updated_at).to eq(t_mark)
  end

  it "respects the subscription_id filter and inclusive before boundary (<= before)" do
    t_exact = Time.utc(2026, 10, 2, 12, 0, 0)
    t_later = t_exact + 1.second
    t_now = Time.utc(2026, 10, 10, 12, 0, 0)

    e_a_exact = create(:entry, feed: feed_a, published_at: t_exact)
    e_a_later = create(:entry, feed: feed_a, published_at: t_later)
    e_b_exact = create(:entry, feed: feed_b, published_at: t_exact)

    marked = travel_to(t_now) do
      described_class.call(user: user, subscription_id: sub_a.id, before: t_exact)
    end
    expect(marked).to eq(1)

    expect(EntryState.find_by(user_id: user.id, entry_id: e_a_exact.id)&.read_at).to eq(t_now)
    expect(EntryState.find_by(user_id: user.id, entry_id: e_a_later.id)).to be_nil
    expect(EntryState.find_by(user_id: user.id, entry_id: e_b_exact.id)).to be_nil
  end

  it "returns the database affected-row count and does not raise when a concurrent insert wins the race during statement (b)" do
    t_pub = Time.utc(2026, 10, 1, 12, 0, 0)
    t_race = Time.utc(2026, 10, 10, 11, 0, 0)
    t_mark = Time.utc(2026, 10, 10, 12, 0, 0)

    entry = create(:entry, feed: feed_a, published_at: t_pub)

    # Simulate another request inserting the row (still unread or already present) between candidate evaluation and the INSERT target check
    allow(EntryState.connection).to receive(:update).and_wrap_original do |original, sql, *args|
      if sql.is_a?(String) && sql.start_with?("INSERT INTO entry_states")
        EntryState.create!(
          user_id: user.id,
          entry_id: entry.id,
          read_at: nil,
          starred_at: t_race,
          created_at: t_race,
          updated_at: t_race
        )
        sql = sql.sub(/AND \(NOT EXISTS \([^)]+\)\)/, "")
      end
      original.call(sql, *args)
    end

    marked = travel_to(t_mark) do
      described_class.call(user: user, before: t_pub)
    end

    # Neither statement (a) nor statement (b) affected a row (ON CONFLICT DO NOTHING skipped the duplicate)
    expect(marked).to eq(0)
    expect(EntryState.where(user_id: user.id, entry_id: entry.id).count).to eq(1)
  end

  it "reads Time.current only after the write transaction is materialized" do
    t_pub = Time.utc(2026, 10, 1, 12, 0, 0)
    t_before_lock = Time.utc(2026, 10, 10, 10, 0, 0)
    t_after_lock = Time.utc(2026, 10, 10, 10, 0, 5)

    e_new = create(:entry, feed: feed_a, published_at: t_pub)
    e_existing = create(:entry, feed: feed_a, published_at: t_pub)
    s_existing = create(:entry_state, user: user, entry: e_existing, read_at: nil, starred_at: t_pub, created_at: t_pub, updated_at: t_pub)

    events = []
    sub = ActiveSupport::Notifications.subscribe("sql.active_record") do |_name, _start, _finish, _id, payload|
      sql = payload[:sql].to_s.strip
      events << :begin if sql.match?(/\A(BEGIN|SAVEPOINT)\b/i)
    end

    allow(Time).to receive(:current) do
      events << :time_current
      events.include?(:begin) ? t_after_lock : t_before_lock
    end

    begin
      marked = described_class.call(user: user, before: t_pub)
      expect(marked).to eq(2)
    ensure
      ActiveSupport::Notifications.unsubscribe(sub)
    end

    expect(events.index(:begin)).not_to be_nil
    expect(events.index(:time_current)).to be > events.index(:begin)

    s_created = EntryState.find_by!(user_id: user.id, entry_id: e_new.id)
    expect(s_created.read_at).to eq(t_after_lock)
    expect(s_created.updated_at).to eq(t_after_lock)

    s_existing.reload
    expect(s_existing.read_at).to eq(t_after_lock)
    expect(s_existing.updated_at).to eq(t_after_lock)
  end
end
