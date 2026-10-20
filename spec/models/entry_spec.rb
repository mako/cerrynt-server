require 'rails_helper'

RSpec.describe Entry, type: :model do
  describe "validations" do
    it "is valid with valid attributes" do
      expect(build(:entry)).to be_valid
    end

    it "requires a guid" do
      entry = build(:entry, guid: nil)
      expect(entry).not_to be_valid
      expect(entry.errors[:guid]).to include("can't be blank")
    end

    it "requires a url" do
      entry = build(:entry, url: nil)
      expect(entry).not_to be_valid
      expect(entry.errors[:url]).to include("can't be blank")
    end

    it "requires a published_at" do
      entry = build(:entry, published_at: nil)
      expect(entry).not_to be_valid
      expect(entry.errors[:published_at]).to include("can't be blank")

      expect {
        entry.save(validate: false)
      }.to raise_error(ActiveRecord::NotNullViolation)
    end

    it "requires a unique guid per feed" do
      feed = create(:feed)
      create(:entry, feed: feed, guid: "123")

      entry = build(:entry, feed: feed, guid: "123")
      expect(entry).not_to be_valid
      expect(entry.errors[:guid]).to include("has already been taken")
    end

    it "raises database error on duplicate guid per feed" do
      feed = create(:feed)
      create(:entry, feed: feed, guid: "123")

      expect {
        build(:entry, feed: feed, guid: "123").save(validate: false)
      }.to raise_error(ActiveRecord::RecordNotUnique)
    end
  end

  describe "associations" do
    it "destroys associated records when destroyed" do
      entry = create(:entry)
      create(:entry_state, entry: entry)

      expect { entry.destroy }.to change(EntryState, :count).by(-1)
    end
  end

  describe ".unread_counts_for" do
    let(:user) { create(:user) }
    let(:other_user) { create(:user) }
    let(:feed1) { create(:feed) }
    let(:feed2) { create(:feed) }
    let(:feed3) { create(:feed) }

    it "returns an empty hash when no feed_ids are provided or feeds have no entries" do
      expect(described_class.unread_counts_for(user, [])).to eq({})
      expect(described_class.unread_counts_for(user, [ feed1.id, feed2.id ])).to eq({})
    end

    it "differentiates read vs unread entries, treating unread when entry_state has read_at: nil" do
      _unread_entry = create(:entry, feed: feed1, guid: "g1")
      read_entry = create(:entry, feed: feed1, guid: "g2")

      create(:entry_state, user: user, entry: read_entry, read_at: 1.hour.ago)

      counts = described_class.unread_counts_for(user, [ feed1.id ])
      expect(counts).to eq({ feed1.id => 1 })
    end

    it "counts starred-only entries as unread" do
      entry = create(:entry, feed: feed1, guid: "starred_unread")
      create(:entry_state, user: user, entry: entry, starred_at: 1.hour.ago, read_at: nil)

      counts = described_class.unread_counts_for(user, [ feed1.id ])
      expect(counts).to eq({ feed1.id => 1 })
    end

    it "ignores other users' entry states" do
      entry1 = create(:entry, feed: feed1, guid: "other_read")
      entry2 = create(:entry, feed: feed1, guid: "both_read")

      create(:entry_state, user: other_user, entry: entry1, read_at: 1.hour.ago)
      create(:entry_state, user: other_user, entry: entry2, read_at: 1.hour.ago)
      create(:entry_state, user: user, entry: entry2, read_at: 1.hour.ago)

      counts = described_class.unread_counts_for(user, [ feed1.id ])
      expect(counts).to eq({ feed1.id => 1 })
    end

    it "computes counts across several feeds in a single call, also accepting user ID" do
      create(:entry, feed: feed1, guid: "f1_e1")
      create(:entry, feed: feed1, guid: "f1_e2")
      create(:entry, feed: feed2, guid: "f2_e1")

      counts = described_class.unread_counts_for(user.id, [ feed1.id, feed2.id, feed3.id ])
      expect(counts).to eq({ feed1.id => 2, feed2.id => 1 })
    end
  end

  describe ".visible_to" do
    let(:user) { create(:user) }
    let(:other_user) { create(:user) }
    let(:shared_feed) { create(:feed) }
    let(:other_feed) { create(:feed) }

    it "returns only entries for feeds the user follows, exposes subscription_id and user state, and never leaks another user's subscription or state" do
      user_sub = create(:subscription, user: user, feed: shared_feed)
      create(:subscription, user: other_user, feed: shared_feed)
      create(:subscription, user: other_user, feed: other_feed)

      entry_no_state = create(:entry, feed: shared_feed, guid: "v-1")
      entry_with_state = create(:entry, feed: shared_feed, guid: "v-2")
      _foreign_entry = create(:entry, feed: other_feed, guid: "v-3")

      # Other user marks entry_no_state as read & starred; user has no state row for it
      create(:entry_state, user: other_user, entry: entry_no_state, read_at: 1.hour.ago, starred_at: 1.hour.ago)
      # User marks entry_with_state as read & starred
      read_time = 30.minutes.ago
      star_time = 20.minutes.ago
      create(:entry_state, user: user, entry: entry_with_state, read_at: read_time, starred_at: star_time)

      rel = described_class.visible_to(user)
      expect(rel.exists?(id: entry_no_state.id)).to be(true)
      expect(rel.pluck(:id)).to contain_exactly(entry_no_state.id, entry_with_state.id)

      by_id = rel.index_by(&:id)
      expect(by_id.keys).to contain_exactly(entry_no_state.id, entry_with_state.id)

      e1 = by_id[entry_no_state.id]
      expect(e1[:subscription_id]).to eq(user_sub.id)
      expect(e1[:state_read_at]).to be_nil
      expect(e1[:state_starred_at]).to be_nil

      e2 = by_id[entry_with_state.id]
      expect(e2[:subscription_id]).to eq(user_sub.id)
      expect(e2[:state_read_at]).to be_present
      expect(e2[:state_starred_at]).to be_present
    end
  end
end
