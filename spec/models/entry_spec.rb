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
end
