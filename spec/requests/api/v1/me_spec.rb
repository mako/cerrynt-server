require 'rails_helper'

RSpec.describe "GET /api/v1/me", type: :request do
  let(:user) { create(:user, email: "me_user@example.com", password: "securepassword123") }
  let(:token_pair) { ApiToken.issue!(user: user, name: "laptop-cli") }
  let(:raw_token) { token_pair[1] }
  let(:auth_headers) { { "Authorization" => "Bearer #{raw_token}" } }

  describe "with valid token" do
    it "returns 200 with the user representation including subscriptions count" do
      feed1 = create(:feed)
      feed2 = create(:feed)
      create(:subscription, user: user, feed: feed1)
      create(:subscription, user: user, feed: feed2)

      get "/api/v1/me", headers: auth_headers

      expect(response).to have_http_status(:ok)

      json = response.parsed_body
      expect(json).to have_key("user")

      user_data = json["user"]
      expect(user_data["id"]).to eq(user.id.to_s)
      expect(user_data["email"]).to eq("me_user@example.com")
      expect(user_data["plan"]).to eq("free")
      expect(user_data["limits"]).to eq({ "max_feeds" => 2 })
      expect(user_data["usage"]).to eq({ "feeds" => 2 })
    end

    it "never includes password, password_digest, or token in response" do
      get "/api/v1/me", headers: auth_headers

      expect(response.body).not_to include("password")
      expect(response.body).not_to include("password_digest")
      expect(response.body).not_to include("securepassword123")
      expect(response.body).not_to include(raw_token)
    end
  end

  describe "authentication failures" do
    it "returns 401 without a token" do
      get "/api/v1/me"

      expect(response).to have_http_status(:unauthorized)
      expect(response.headers["WWW-Authenticate"]).to eq("Bearer")
      expect(response.parsed_body["error"]["code"]).to eq("unauthorized")
    end

    it "returns 401 with a revoked token" do
      token_pair[0].update_columns(revoked_at: Time.current)

      get "/api/v1/me", headers: auth_headers

      expect(response).to have_http_status(:unauthorized)
      expect(response.headers["WWW-Authenticate"]).to eq("Bearer")
      expect(response.parsed_body["error"]["code"]).to eq("unauthorized")
    end
  end
end
