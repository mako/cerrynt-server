# frozen_string_literal: true

require "rails_helper"

RSpec.describe Entries::Changes do
  include ActiveSupport::Testing::TimeHelpers

  let(:user) { create(:user, plan: "pro") }
  let(:other_user) { create(:user, plan: "pro") }

  def count_queries(&block)
    queries = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |_name, _start, _finish, _id, payload|
      sql = payload[:sql].to_s.strip
      name = payload[:name].to_s
      unless name == "SCHEMA" || name == "TRANSACTION" || sql.match?(/\A(BEGIN|COMMIT|ROLLBACK|SAVEPOINT|RELEASE)\b/i)
        queries << sql
      end
    end
    block.call
    queries.size
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end

  it "raises ArgumentError when since is not nil or a decoded [Time, Integer] pair" do
    expect { described_class.call(user: user, since: "raw-cursor") }.to raise_error(ArgumentError)
    expect { described_class.call(user: user, since: [ Time.current ]) }.to raise_error(ArgumentError)
    expect { described_class.call(user: user, since: [ "2026-10-21", 1 ]) }.to raise_error(ArgumentError)
    expect { described_class.call(user: user, since: [ Time.current, "1" ]) }.to raise_error(ArgumentError)
    expect { described_class.call(user: user, since: [ Time.current, -1 ]) }.to raise_error(ArgumentError)
  end

  it "returns empty subscriptions, empty entries, EPOCH cursor, and has_more false when the user has no subscriptions" do
    create(:user)
    unfollowed_feed = create(:feed)
    create(:subscription, user: other_user, feed: unfollowed_feed)
    create(:entry, feed: unfollowed_feed)

    result = described_class.call(user: user)
    expect(result).to eq(
      subscriptions: [],
      entries: [],
      cursor: Entries::SyncCursor::EPOCH,
      has_more: false
    )
  end

  it "returns the full subscriptions snapshot with unread_count and all visible entries ordered by (changed_at, id) on first sync, with String ids and no changed_at key" do
    t_sub = Time.utc(2026, 10, 1, 10, 0, 0)
    t_e1 = Time.utc(2026, 10, 2, 10, 0, 0, 100_000)
    t_e2 = Time.utc(2026, 10, 3, 10, 0, 0, 200_000)

    feed = create(:feed, title: "Tech Feed", site_url: "https://tech.example.com")
    sub = travel_to(t_sub) { create(:subscription, user: user, feed: feed) }

    e2 = create(:entry, feed: feed, title: "Newer Change", published_at: t_sub, created_at: t_e2, updated_at: t_e2)
    e1 = create(:entry, feed: feed, title: "Older Change", published_at: t_e2, created_at: t_e1, updated_at: t_e1)

    result = described_class.call(user: user)

    expect(result[:has_more]).to be(false)
    expect(result[:subscriptions]).to eq([
      SubscriptionPresenter.new(sub, unread_count: 2).as_json
    ])
    expect(result[:subscriptions].first[:id]).to be_a(String)
    expect(result[:subscriptions].first[:unread_count]).to eq(2)

    expect(result[:entries].map { |e| e[:id] }).to eq([ e1.id.to_s, e2.id.to_s ])
    result[:entries].each do |entry_hash|
      expect(entry_hash[:id]).to be_a(String)
      expect(entry_hash[:subscription_id]).to eq(sub.id.to_s)
      expect(entry_hash).not_to have_key(:changed_at)
      expect(entry_hash).not_to have_key("changed_at")
    end

    expect(result[:cursor]).to eq(Entries::SyncCursor.encode(changed_at: t_e2, id: e2.id))
  end

  it "paginates 250 entries as 100 / 100 / 50 with has_more true / true / false, full subscriptions snapshot on every page, and no duplicates or gaps" do
    t_base = Time.utc(2026, 10, 1, 12, 0, 0)
    feed = create(:feed)
    sub = create(:subscription, user: user, feed: feed, created_at: t_base, updated_at: t_base)

    expected_ids = (1..250).map do |i|
      t = t_base + i.seconds
      create(:entry, feed: feed, published_at: t, created_at: t, updated_at: t).id.to_s
    end

    page1 = described_class.call(user: user)
    expect(page1[:entries].size).to eq(100)
    expect(page1[:has_more]).to be(true)
    expect(page1[:subscriptions].map { |s| s[:id] }).to eq([ sub.id.to_s ])

    page2 = described_class.call(user: user, since: Entries::SyncCursor.decode(page1[:cursor]))
    expect(page2[:entries].size).to eq(100)
    expect(page2[:has_more]).to be(true)
    expect(page2[:subscriptions].map { |s| s[:id] }).to eq([ sub.id.to_s ])

    page3 = described_class.call(user: user, since: Entries::SyncCursor.decode(page2[:cursor]))
    expect(page3[:entries].size).to eq(50)
    expect(page3[:has_more]).to be(false)
    expect(page3[:subscriptions].map { |s| s[:id] }).to eq([ sub.id.to_s ])

    collected_ids = (page1[:entries] + page2[:entries] + page3[:entries]).map { |e| e[:id] }
    expect(collected_ids).to eq(expected_ids)

    page4 = described_class.call(user: user, since: Entries::SyncCursor.decode(page3[:cursor]))
    expect(page4[:entries]).to eq([])
    expect(page4[:has_more]).to be(false)
    expect(page4[:cursor]).to eq(page3[:cursor])
    expect(page4[:subscriptions].map { |s| s[:id] }).to eq([ sub.id.to_s ])
  end

  it "sets has_more to false for exactly 100 entries and true for 101 entries" do
    t_base = Time.utc(2026, 10, 1, 12, 0, 0)
    feed = create(:feed)
    create(:subscription, user: user, feed: feed, created_at: t_base, updated_at: t_base)

    100.times do |i|
      t = t_base + (i + 1).seconds
      create(:entry, feed: feed, published_at: t, created_at: t, updated_at: t)
    end

    res_100 = described_class.call(user: user)
    expect(res_100[:entries].size).to eq(100)
    expect(res_100[:has_more]).to be(false)

    t_101 = t_base + 101.seconds
    create(:entry, feed: feed, published_at: t_101, created_at: t_101, updated_at: t_101)

    res_101 = described_class.call(user: user)
    expect(res_101[:entries].size).to eq(100)
    expect(res_101[:has_more]).to be(true)
  end

  it "surfaces an entry updated by Feeds::Refresh even when an older entry_state row already exists" do
    t_sub = Time.utc(2026, 10, 1, 10, 0, 0)
    t_entry = Time.utc(2026, 10, 1, 11, 0, 0)
    t_state = Time.utc(2026, 10, 1, 12, 0, 0)
    t_refresh = Time.utc(2026, 10, 1, 13, 0, 0, 456_789)

    feed = create(:feed)
    create(:subscription, user: user, feed: feed, created_at: t_sub, updated_at: t_sub)
    entry = create(:entry, feed: feed, guid: "g-1", url: "https://example.com/1", title: "Initial", published_at: t_entry, created_at: t_entry, updated_at: t_entry)

    travel_to(t_state, with_usec: true) do
      Entries::UpdateState.call(user: user, entry_id: entry.id, read: true)
    end

    sync1 = described_class.call(user: user)
    expect(sync1[:entries].map { |e| e[:id] }).to eq([ entry.id.to_s ])
    expect(Entries::SyncCursor.decode(sync1[:cursor])).to eq([ t_state, entry.id ])

    # Now Feeds::Refresh updates the entry's title at t_refresh > t_state
    parsed_entry = Feeds::Fetcher::ParsedEntry.new(
      guid: "g-1",
      url: "https://example.com/1",
      title: "Updated Title",
      author: "Alice",
      summary: "Sum",
      content: "<p>Body</p>",
      published_at: t_entry
    )
    fetch_result = Feeds::Fetcher::Result.new(
      success: true,
      error: nil,
      message: nil,
      status: 200,
      final_url: feed.url,
      etag: nil,
      last_modified: nil,
      feed: Feeds::Fetcher::ParsedFeed.new(title: "Feed", site_url: "https://example.com", entries: [ parsed_entry ])
    )

    travel_to(t_refresh, with_usec: true) do
      Feeds::Refresh.call(feed, fetcher: ->(_u) { fetch_result })
    end

    sync2 = described_class.call(user: user, since: Entries::SyncCursor.decode(sync1[:cursor]))
    expect(sync2[:entries].size).to eq(1)
    expect(sync2[:entries].first[:id]).to eq(entry.id.to_s)
    expect(sync2[:entries].first[:title]).to eq("Updated Title")
    expect(sync2[:entries].first[:read]).to be(true)
    expect(Entries::SyncCursor.decode(sync2[:cursor])).to eq([ t_refresh, entry.id ])
  end

  it "surfaces read, starred, and cleared-tombstone changes via entry_states.updated_at" do
    t_initial = Time.utc(2026, 10, 1, 10, 0, 0)
    t_read = Time.utc(2026, 10, 1, 11, 0, 0, 111_111)
    t_star = Time.utc(2026, 10, 1, 12, 0, 0, 222_222)
    t_clear = Time.utc(2026, 10, 1, 13, 0, 0, 333_333)

    feed = create(:feed)
    create(:subscription, user: user, feed: feed, created_at: t_initial, updated_at: t_initial)
    entry = create(:entry, feed: feed, published_at: t_initial, created_at: t_initial, updated_at: t_initial)

    sync0 = described_class.call(user: user)
    cursor = sync0[:cursor]

    # 1. Mark read
    travel_to(t_read, with_usec: true) { Entries::UpdateState.call(user: user, entry_id: entry.id, read: true) }
    sync1 = described_class.call(user: user, since: Entries::SyncCursor.decode(cursor))
    expect(sync1[:entries].size).to eq(1)
    expect(sync1[:entries].first).to include(id: entry.id.to_s, read: true, starred: false)
    expect(Entries::SyncCursor.decode(sync1[:cursor])).to eq([ t_read, entry.id ])

    # 2. Mark starred
    travel_to(t_star, with_usec: true) { Entries::UpdateState.call(user: user, entry_id: entry.id, starred: true) }
    sync2 = described_class.call(user: user, since: Entries::SyncCursor.decode(sync1[:cursor]))
    expect(sync2[:entries].size).to eq(1)
    expect(sync2[:entries].first).to include(id: entry.id.to_s, read: true, starred: true)
    expect(Entries::SyncCursor.decode(sync2[:cursor])).to eq([ t_star, entry.id ])

    # 3. Clear both -> tombstone row kept with both nil and updated_at = t_clear
    travel_to(t_clear, with_usec: true) { Entries::UpdateState.call(user: user, entry_id: entry.id, read: false, starred: false) }
    sync3 = described_class.call(user: user, since: Entries::SyncCursor.decode(sync2[:cursor]))
    expect(sync3[:entries].size).to eq(1)
    expect(sync3[:entries].first).to include(id: entry.id.to_s, read: false, starred: false)
    expect(Entries::SyncCursor.decode(sync3[:cursor])).to eq([ t_clear, entry.id ])
  end

  it "surfaces old entries of a newly subscribed feed via subscriptions.created_at, and re-sends them with the new subscription_id on re-subscribe after delete" do
    t_old = Time.utc(2026, 10, 1, 10, 0, 0)
    t_sub1 = Time.utc(2026, 10, 5, 10, 0, 0)
    t_sub2 = Time.utc(2026, 10, 6, 10, 0, 0, 654_321)
    t_resub = Time.utc(2026, 10, 7, 10, 0, 0, 777_777)

    feed_a = create(:feed)
    feed_b = create(:feed)
    old_entry_b = create(:entry, feed: feed_b, published_at: t_old, created_at: t_old, updated_at: t_old)
    entry_a = create(:entry, feed: feed_a, published_at: t_sub1, created_at: t_sub1, updated_at: t_sub1)

    sub_a = create(:subscription, user: user, feed: feed_a, created_at: t_sub1, updated_at: t_sub1)

    sync1 = described_class.call(user: user)
    expect(sync1[:entries].map { |e| e[:id] }).to eq([ entry_a.id.to_s ])

    # User subscribes to already-known feed_b (whose entry was updated at t_old < t_sub1)
    sub_b1 = create(:subscription, user: user, feed: feed_b, created_at: t_sub2, updated_at: t_sub2)

    sync2 = described_class.call(user: user, since: Entries::SyncCursor.decode(sync1[:cursor]))
    expect(sync2[:entries].size).to eq(1)
    expect(sync2[:entries].first).to include(id: old_entry_b.id.to_s, subscription_id: sub_b1.id.to_s)
    expect(Entries::SyncCursor.decode(sync2[:cursor])).to eq([ t_sub2, old_entry_b.id ])

    # User deletes sub_b1 -> disappears from snapshot and entries
    sub_b1.destroy!
    sync3 = described_class.call(user: user, since: Entries::SyncCursor.decode(sync2[:cursor]))
    expect(sync3[:entries]).to eq([])
    expect(sync3[:subscriptions].map { |s| s[:id] }).to eq([ sub_a.id.to_s ])

    # User re-subscribes to feed_b at t_resub -> old_entry_b is re-sent with the new subscription_id
    sub_b2 = create(:subscription, user: user, feed: feed_b, created_at: t_resub, updated_at: t_resub)
    sync4 = described_class.call(user: user, since: Entries::SyncCursor.decode(sync3[:cursor]))
    expect(sync4[:entries].size).to eq(1)
    expect(sync4[:entries].first).to include(id: old_entry_b.id.to_s, subscription_id: sub_b2.id.to_s)
    expect(sync4[:subscriptions].map { |s| s[:id] }).to eq([ sub_a.id.to_s, sub_b2.id.to_s ])
    expect(Entries::SyncCursor.decode(sync4[:cursor])).to eq([ t_resub, old_entry_b.id ])
  end

  it "excludes unfollowed feeds, deleted subscriptions, and other users' subscriptions and state changes" do
    t_initial = Time.utc(2026, 10, 1, 10, 0, 0)
    t_other_state = Time.utc(2026, 10, 2, 10, 0, 0)

    shared_feed = create(:feed)
    unfollowed_feed = create(:feed)

    user_sub = create(:subscription, user: user, feed: shared_feed, created_at: t_initial, updated_at: t_initial)
    create(:subscription, user: other_user, feed: shared_feed, created_at: t_initial, updated_at: t_initial)
    create(:subscription, user: other_user, feed: unfollowed_feed, created_at: t_initial, updated_at: t_initial)

    shared_entry = create(:entry, feed: shared_feed, published_at: t_initial, created_at: t_initial, updated_at: t_initial)
    create(:entry, feed: unfollowed_feed, published_at: t_other_state, created_at: t_other_state, updated_at: t_other_state)

    sync1 = described_class.call(user: user)
    expect(sync1[:subscriptions].map { |s| s[:id] }).to eq([ user_sub.id.to_s ])
    expect(sync1[:entries].map { |e| e[:id] }).to eq([ shared_entry.id.to_s ])

    # Other user marks shared_entry as read at t_other_state -> must not trigger a sync delta for user
    travel_to(t_other_state) do
      Entries::UpdateState.call(user: other_user, entry_id: shared_entry.id, read: true)
    end

    sync2 = described_class.call(user: user, since: Entries::SyncCursor.decode(sync1[:cursor]))
    expect(sync2[:entries]).to eq([])
    expect(sync2[:cursor]).to eq(sync1[:cursor])
    expect(sync2[:subscriptions].map { |s| s[:id] }).to eq([ user_sub.id.to_s ])
  end

  it "orders entries sharing the exact same changed_at by id ASC and neither skips nor duplicates across a page boundary" do
    t_same = Time.utc(2026, 10, 10, 12, 0, 0, 123_456)
    feed = create(:feed)
    create(:subscription, user: user, feed: feed, created_at: t_same, updated_at: t_same)

    entries = Array.new(105) do
      create(:entry, feed: feed, published_at: t_same, created_at: t_same, updated_at: t_same)
    end
    expected_ids = entries.map { |e| e.id.to_s }

    page1 = described_class.call(user: user)
    expect(page1[:entries].size).to eq(100)
    expect(page1[:has_more]).to be(true)

    page2 = described_class.call(user: user, since: Entries::SyncCursor.decode(page1[:cursor]))
    expect(page2[:entries].size).to eq(5)
    expect(page2[:has_more]).to be(false)

    expect((page1[:entries] + page2[:entries]).map { |e| e[:id] }).to eq(expected_ids)
  end

  it "orders rows at :20.000000, :20.000001, and :20.500000 accurately across a page boundary" do
    t_sub = Time.utc(2026, 10, 1, 10, 0, 0)
    t_zero = Time.utc(2026, 10, 21, 22, 4, 20, 0)
    t_one_usec = Time.utc(2026, 10, 21, 22, 4, 20, 1)
    t_half_sec = Time.utc(2026, 10, 21, 22, 4, 20, 500_000)

    feed = create(:feed)
    create(:subscription, user: user, feed: feed, created_at: t_sub, updated_at: t_sub)

    # Create 99 earlier entries so the 100th row on page 1 is t_zero (or t_one_usec)
    99.times do |i|
      t = t_sub + (i + 1).seconds
      create(:entry, feed: feed, published_at: t, created_at: t, updated_at: t)
    end

    # Insert in reverse id order to verify timestamp takes precedence over id
    e_half = create(:entry, feed: feed, published_at: t_sub, created_at: t_half_sec, updated_at: t_half_sec)
    e_usec = create(:entry, feed: feed, published_at: t_sub, created_at: t_one_usec, updated_at: t_one_usec)
    e_zero = create(:entry, feed: feed, published_at: t_sub, created_at: t_zero, updated_at: t_zero)

    page1 = described_class.call(user: user)
    expect(page1[:entries].size).to eq(100)
    expect(page1[:has_more]).to be(true)
    expect(page1[:entries].last[:id]).to eq(e_zero.id.to_s)
    expect(Entries::SyncCursor.decode(page1[:cursor])).to eq([ t_zero, e_zero.id ])

    page2 = described_class.call(user: user, since: Entries::SyncCursor.decode(page1[:cursor]))
    expect(page2[:entries].map { |e| e[:id] }).to eq([ e_usec.id.to_s, e_half.id.to_s ])
    expect(page2[:has_more]).to be(false)
    expect(Entries::SyncCursor.decode(page2[:cursor])).to eq([ t_half_sec, e_half.id ])
  end

  it "executes the entries SELECT before the subscriptions SELECT" do
    feed = create(:feed)
    create(:subscription, user: user, feed: feed)
    create(:entry, feed: feed)

    sql_events = []
    sub = ActiveSupport::Notifications.subscribe("sql.active_record") do |_name, _start, _finish, _id, payload|
      sql = payload[:sql].to_s.strip
      if sql.include?("AS changed_at")
        sql_events << :entries_query
      elsif sql.start_with?('SELECT "subscriptions".* FROM "subscriptions"')
        sql_events << :subscriptions_query
      end
    end

    begin
      described_class.call(user: user)
    ensure
      ActiveSupport::Notifications.unsubscribe(sub)
    end

    expect(sql_events).to eq([ :entries_query, :subscriptions_query ])
  end

  it "executes a constant number of SQL queries for 5 vs 100 entries and 1 vs 5 subscriptions" do
    feed1 = create(:feed)
    create(:subscription, user: user, feed: feed1)
    5.times { create(:entry, feed: feed1) }

    queries_small = count_queries do
      described_class.call(user: user)
    end

    4.times do
      f = create(:feed)
      create(:subscription, user: user, feed: f)
      25.times { create(:entry, feed: f) }
    end

    queries_large = count_queries do
      described_class.call(user: user)
    end

    expect(queries_large).to eq(queries_small)
    expect(queries_large).to eq(4)
  end
end
