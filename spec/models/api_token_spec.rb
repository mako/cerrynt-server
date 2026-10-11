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

    it "requires a name" do
      token = build(:api_token, name: nil)
      expect(token).not_to be_valid
      expect(token.errors[:name]).to include("can't be blank")
    end

    it "requires name to be at most 100 characters" do
      token = build(:api_token, name: "a" * 101)
      expect(token).not_to be_valid
      expect(token.errors[:name]).to include("is too long (maximum is 100 characters)")
    end
  end

  describe ".digest" do
    it "returns the SHA-256 hexdigest of the input" do
      expect(ApiToken.digest("test")).to eq(Digest::SHA256.hexdigest("test"))
    end
  end

  describe ".issue!" do
    let(:user) { create(:user) }

    it "creates an api token and returns the record and raw token" do
      token, raw_token = ApiToken.issue!(user: user, name: "laptop-cli")

      expect(token).to be_persisted
      expect(token.user).to eq(user)
      expect(token.name).to eq("laptop-cli")
      expect(raw_token).to start_with("cyn_")
      expect(token.token_digest).to eq(ApiToken.digest(raw_token))
    end

    it "does not persist the raw token to the database" do
      _token, raw_token = ApiToken.issue!(user: user, name: "laptop-cli")

      raw_in_db = ApiToken.where(token_digest: raw_token).or(ApiToken.where(name: raw_token))
      expect(raw_in_db).to be_empty
    end

    it "raises when name is invalid" do
      expect {
        ApiToken.issue!(user: user, name: nil)
      }.to raise_error(ActiveRecord::RecordInvalid)
    end
  end

  describe ".active scope" do
    let(:user) { create(:user) }

    it "includes non-revoked tokens and excludes revoked tokens" do
      active_token = create(:api_token, user: user, revoked_at: nil)
      revoked_token = create(:api_token, user: user, revoked_at: 1.day.ago)

      expect(described_class.active).to include(active_token)
      expect(described_class.active).not_to include(revoked_token)
    end
  end

  describe "#touch_last_used_at!" do
    include ActiveSupport::Testing::TimeHelpers

    let(:token) { create(:api_token) }

    it "sets last_used_at when nil" do
      freeze_time do
        expect { token.touch_last_used_at! }.to change { token.reload.last_used_at }.from(nil).to(Time.current)
      end
    end

    it "does not update last_used_at when within 1 hour" do
      token.update_columns(last_used_at: 30.minutes.ago)

      expect { token.touch_last_used_at! }.not_to(change { token.reload.last_used_at })
    end

    it "updates last_used_at when older than 1 hour" do
      token.update_columns(last_used_at: 2.hours.ago)

      freeze_time do
        expect { token.touch_last_used_at! }.to change { token.reload.last_used_at }.to(Time.current)
      end
    end
  end
end
