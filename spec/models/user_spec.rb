require 'rails_helper'

RSpec.describe User, type: :model do
  describe "validations" do
    it "is valid with valid attributes" do
      expect(build(:user)).to be_valid
    end

    it "requires an email" do
      user = build(:user, email: nil)
      expect(user).not_to be_valid
      expect(user.errors[:email]).to include("can't be blank")
    end

    it "requires a valid email format" do
      user = build(:user, email: "invalid")
      expect(user).not_to be_valid
      expect(user.errors[:email]).to include("is invalid")
    end

    it "requires a unique email (case-insensitive)" do
      create(:user, email: "test@example.com")
      user = build(:user, email: "TEST@EXAMPLE.COM")
      expect(user).not_to be_valid
      expect(user.errors[:email]).to include("has already been taken")
    end

    it "raises database error on duplicate email" do
      create(:user, email: "test@example.com")
      expect {
        build(:user, email: "test@example.com").save(validate: false)
      }.to raise_error(ActiveRecord::RecordNotUnique)
    end

    it "requires a valid plan" do
      user = build(:user, plan: "invalid")
      expect(user).not_to be_valid
      expect(user.errors[:plan]).to include("is not included in the list")
    end
  end

  describe "normalization" do
    it "downcases and strips email" do
      user = User.new(email: "  TEST@Example.com  ")
      expect(user.email).to eq("test@example.com")
    end
  end

  describe "associations" do
    it "destroys associated records when destroyed" do
      user = create(:user)
      create(:api_token, user: user)
      feed = create(:feed)
      create(:subscription, user: user, feed: feed)
      entry = create(:entry, feed: feed)
      create(:entry_state, user: user, entry: entry)

      expect { user.destroy }.to change(ApiToken, :count).by(-1)
        .and change(Subscription, :count).by(-1)
        .and change(EntryState, :count).by(-1)
    end
  end
end
