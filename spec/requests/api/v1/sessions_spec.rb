require 'rails_helper'

RSpec.describe "POST /api/v1/sessions", type: :request do
  let!(:user) { create(:user, email: "user@example.com", password: "securepassword123") }
  let(:valid_params) do
    { email: "user@example.com", password: "securepassword123", device_name: "laptop-cli" }
  end

  describe "with valid credentials" do
    it "returns 201 with raw token and user payload" do
      expect {
        post "/api/v1/sessions", params: valid_params, as: :json
      }.to change(ApiToken, :count).by(1)

      expect(response).to have_http_status(:created)

      json = response.parsed_body
      expect(json).to have_key("token")
      expect(json).to have_key("user")

      raw_token = json["token"]
      expect(raw_token).to start_with("cyn_")

      created_token = ApiToken.last
      expect(created_token.user).to eq(user)
      expect(created_token.name).to eq("laptop-cli")
      expect(created_token.token_digest).to eq(ApiToken.digest(raw_token))

      # The database must not store the raw token
      expect(ApiToken.where(token_digest: raw_token)).to be_empty

      user_data = json["user"]
      expect(user_data["id"]).to eq(user.id.to_s)
      expect(user_data["email"]).to eq("user@example.com")
      expect(user_data["plan"]).to eq("free")
      expect(user_data["limits"]).to eq({ "max_feeds" => 2 })
      expect(user_data["usage"]).to eq({ "feeds" => 0 })
    end

    it "logs in with case-insensitive and whitespace-padded email" do
      post "/api/v1/sessions",
           params: { email: "  USER@Example.COM ", password: "securepassword123", device_name: "laptop-cli" },
           as: :json

      expect(response).to have_http_status(:created)
      expect(response.parsed_body["user"]["email"]).to eq("user@example.com")
    end

    it "creates separate tokens across two logins" do
      post "/api/v1/sessions", params: valid_params, as: :json
      token1 = response.parsed_body["token"]

      post "/api/v1/sessions", params: valid_params.merge(device_name: "phone-cli"), as: :json
      token2 = response.parsed_body["token"]

      expect(token1).not_to eq(token2)
      expect(user.api_tokens.count).to eq(2)
      expect(user.api_tokens.pluck(:name)).to contain_exactly("laptop-cli", "phone-cli")
    end

    it "does not include password or password_digest in the response" do
      post "/api/v1/sessions", params: valid_params, as: :json

      expect(response.body).not_to include("password")
      expect(response.body).not_to include("password_digest")
      expect(response.body).not_to include("securepassword123")
    end
  end

  describe "with invalid credentials" do
    it "returns identical 401 invalid_credentials for wrong password and unknown email" do
      post "/api/v1/sessions",
           params: { email: "user@example.com", password: "wrongpassword", device_name: "laptop-cli" },
           as: :json

      expect(response).to have_http_status(:unauthorized)
      wrong_pw_response = response.parsed_body

      post "/api/v1/sessions",
           params: { email: "unknown@example.com", password: "securepassword123", device_name: "laptop-cli" },
           as: :json

      expect(response).to have_http_status(:unauthorized)
      unknown_email_response = response.parsed_body

      expect(wrong_pw_response).to eq(unknown_email_response)
      expect(wrong_pw_response["error"]["code"]).to eq("invalid_credentials")
      expect(wrong_pw_response["error"]["message"]).to eq("Wrong email or password")
      expect(wrong_pw_response["error"]["details"]).to eq({})
    end

    it "returns 401 invalid_credentials when email is missing" do
      post "/api/v1/sessions",
           params: { password: "securepassword123", device_name: "laptop-cli" },
           as: :json

      expect(response).to have_http_status(:unauthorized)
      json = response.parsed_body
      expect(json["error"]["code"]).to eq("invalid_credentials")
      expect(json["error"]["message"]).to eq("Wrong email or password")
    end

    it "returns 401 invalid_credentials when password is missing" do
      post "/api/v1/sessions",
           params: { email: "user@example.com", device_name: "laptop-cli" },
           as: :json

      expect(response).to have_http_status(:unauthorized)
      json = response.parsed_body
      expect(json["error"]["code"]).to eq("invalid_credentials")
      expect(json["error"]["message"]).to eq("Wrong email or password")
    end

    it "returns 401 invalid_credentials when empty payload is sent" do
      post "/api/v1/sessions", params: {}, as: :json

      expect(response).to have_http_status(:unauthorized)
      json = response.parsed_body
      expect(json["error"]["code"]).to eq("invalid_credentials")
      expect(json["error"]["message"]).to eq("Wrong email or password")
    end
  end

  describe "with invalid device_name" do
    it "returns 422 validation_failed when device_name is missing" do
      post "/api/v1/sessions",
           params: { email: "user@example.com", password: "securepassword123" },
           as: :json

      expect(response).to have_http_status(:unprocessable_content)
      json = response.parsed_body
      expect(json["error"]["code"]).to eq("validation_failed")
      expect(json["error"]["details"]).to have_key("device_name")
      expect(json["error"]["details"]["device_name"]).to include("can't be blank")
    end

    it "returns 422 validation_failed when device_name exceeds 100 characters" do
      post "/api/v1/sessions",
           params: { email: "user@example.com", password: "securepassword123", device_name: "a" * 101 },
           as: :json

      expect(response).to have_http_status(:unprocessable_content)
      json = response.parsed_body
      expect(json["error"]["code"]).to eq("validation_failed")
      expect(json["error"]["details"]).to have_key("device_name")
      expect(json["error"]["details"]["device_name"]).to include("is too long (maximum is 100 characters)")
    end
  end
end
