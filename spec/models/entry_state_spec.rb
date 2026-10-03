require 'rails_helper'

RSpec.describe EntryState, type: :model do
  describe "validations" do
    it "is valid with valid attributes" do
      expect(build(:entry_state)).to be_valid
    end

    it "requires a unique entry per user" do
      user = create(:user)
      entry = create(:entry)
      create(:entry_state, user: user, entry: entry)

      state = build(:entry_state, user: user, entry: entry)
      expect(state).not_to be_valid
      expect(state.errors[:entry_id]).to include("has already been taken")
    end

    it "raises database error on duplicate entry_state" do
      user = create(:user)
      entry = create(:entry)
      create(:entry_state, user: user, entry: entry)

      expect {
        build(:entry_state, user: user, entry: entry).save(validate: false)
      }.to raise_error(ActiveRecord::RecordNotUnique)
    end
  end
end
