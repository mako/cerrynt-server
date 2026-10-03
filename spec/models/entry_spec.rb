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
end
