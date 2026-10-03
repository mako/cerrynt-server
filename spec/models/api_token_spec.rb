require 'rails_helper'

RSpec.describe ApiToken, type: :model do
  describe "validations" do
    it "is valid with valid attributes" do
      expect(build(:api_token)).to be_valid
    end

    it "requires a token_digest" do
      token = build(:api_token, token_digest: nil)
      expect(token).not_to be_valid
      expect(token.errors[:token_digest]).to include("can't be blank")
    end

    it "requires a unique token_digest" do
      create(:api_token, token_digest: "hash123")
      token = build(:api_token, token_digest: "hash123")
      expect(token).not_to be_valid
      expect(token.errors[:token_digest]).to include("has already been taken")
    end

    it "raises database error on duplicate token_digest" do
      create(:api_token, token_digest: "hash123")
      expect {
        build(:api_token, token_digest: "hash123").save(validate: false)
      }.to raise_error(ActiveRecord::RecordNotUnique)
    end
  end

  describe ".digest" do
    it "returns the SHA-256 hexdigest of the input" do
      expect(ApiToken.digest("test")).to eq(Digest::SHA256.hexdigest("test"))
    end
  end
end
