require 'rails_helper'

RSpec.describe Subscription, type: :model do
  describe "validations" do
    it "is valid with valid attributes" do
      expect(build(:subscription)).to be_valid
    end

    it "requires a unique feed per user" do
      user = create(:user)
      feed = create(:feed)
      create(:subscription, user: user, feed: feed)

      sub = build(:subscription, user: user, feed: feed)
      expect(sub).not_to be_valid
      expect(sub.errors[:feed_id]).to include("has already been taken")
    end

    it "raises database error on duplicate subscription" do
      user = create(:user)
      feed = create(:feed)
      create(:subscription, user: user, feed: feed)

      expect {
        build(:subscription, user: user, feed: feed).save(validate: false)
      }.to raise_error(ActiveRecord::RecordNotUnique)
    end
  end
end
