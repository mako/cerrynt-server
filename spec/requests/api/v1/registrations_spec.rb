require 'rails_helper'

RSpec.describe "POST /api/v1/registrations", type: :request do
  let(:valid_params) do
    { email: "user@example.com", password: "securepassword123" }
  end

  describe "with valid parameters" do
    it "creates a new user and returns 201 with the user representation" do
      expect {
        post "/api/v1/registrations", params: valid_params, as: :json
      }.to change(User, :count).by(1)

      expect(response).to have_http_status(:created)

      json = response.parsed_body
      expect(json).to have_key("user")

      user_data = json["user"]
      expect(user_data["id"]).to be_a(String)
      expect(user_data["email"]).to eq("user@example.com")
      expect(user_data["plan"]).to eq("free")
      expect(user_data["limits"]).to eq({ "max_feeds" => 2 })
      expect(user_data["usage"]).to eq({ "feeds" => 0 })
    end

    it "ignores client-supplied plan and defaults to free" do
      post "/api/v1/registrations",
           params: valid_params.merge(plan: "pro"),
           as: :json

      expect(response).to have_http_status(:created)
      json = response.parsed_body
      expect(json["user"]["plan"]).to eq("free")

      created_user = User.find_by(email: valid_params[:email])
      expect(created_user.plan).to eq("free")
    end

    it "normalizes email by trimming whitespace and downcasing" do
      post "/api/v1/registrations",
           params: { email: "  USER@Example.COM ", password: "securepassword123" },
           as: :json

      expect(response).to have_http_status(:created)
      json = response.parsed_body
      expect(json["user"]["email"]).to eq("user@example.com")

      created_user = User.find_by(email: "user@example.com")
      expect(created_user).to be_present
      expect(created_user.email).to eq("user@example.com")
    end

    it "does not include password or password_digest in the response" do
      post "/api/v1/registrations", params: valid_params, as: :json

      expect(response.body).not_to include("password")
      expect(response.body).not_to include("password_digest")
      expect(response.body).not_to include("securepassword123")
    end
  end

  describe "with duplicate email" do
    before do
      create(:user, email: "existing@example.com")
    end

    it "returns 422 validation_failed (case-insensitive)" do
      expect {
        post "/api/v1/registrations",
             params: { email: "EXISTING@example.com", password: "securepassword123" },
             as: :json
      }.not_to change(User, :count)

      expect(response).to have_http_status(:unprocessable_content)

      json = response.parsed_body
      expect(json["error"]["code"]).to eq("validation_failed")
      expect(json["error"]["message"]).to eq("Validation failed")
      expect(json["error"]["details"]["email"]).to include("has already been taken")
    end
  end

  describe "with invalid email" do
    it "returns 422 validation_failed" do
      expect {
        post "/api/v1/registrations",
             params: { email: "not-an-email", password: "securepassword123" },
             as: :json
      }.not_to change(User, :count)

      expect(response).to have_http_status(:unprocessable_content)

      json = response.parsed_body
      expect(json["error"]["code"]).to eq("validation_failed")
      expect(json["error"]["details"]["email"]).to include("is invalid")
    end
  end

  describe "with too-short password" do
    it "returns 422 validation_failed and does not echo the password" do
      expect {
        post "/api/v1/registrations",
             params: { email: "valid@example.com", password: "tiny_pass" },
             as: :json
      }.not_to change(User, :count)

      expect(response).to have_http_status(:unprocessable_content)

      json = response.parsed_body
      expect(json["error"]["code"]).to eq("validation_failed")
      expect(json["error"]["details"]["password"]).to include("is too short (minimum is 10 characters)")
      expect(response.body).not_to include("tiny_pass")
    end
  end

  describe "with too-long password (73 bytes)" do
    it "returns 422 validation_failed" do
      expect {
        post "/api/v1/registrations",
             params: { email: "valid@example.com", password: "a" * 73 },
             as: :json
      }.not_to change(User, :count)

      expect(response).to have_http_status(:unprocessable_content)

      json = response.parsed_body
      expect(json["error"]["code"]).to eq("validation_failed")
      expect(json["error"]["details"]["password"]).to include("is too long")
    end
  end

  describe "with missing parameters" do
    it "returns 422 validation_failed when empty payload is provided" do
      expect {
        post "/api/v1/registrations", params: {}, as: :json
      }.not_to change(User, :count)

      expect(response).to have_http_status(:unprocessable_content)

      json = response.parsed_body
      expect(json["error"]["code"]).to eq("validation_failed")
      expect(json["error"]["details"]["email"]).to include("can't be blank")
      expect(json["error"]["details"]["password"]).to include("can't be blank")
    end

    it "returns 422 validation_failed when password is missing" do
      expect {
        post "/api/v1/registrations", params: { email: "valid@example.com" }, as: :json
      }.not_to change(User, :count)

      expect(response).to have_http_status(:unprocessable_content)

      json = response.parsed_body
      expect(json["error"]["code"]).to eq("validation_failed")
      expect(json["error"]["details"]["password"]).to include("can't be blank")
    end

    it "returns 422 validation_failed when email is missing" do
      expect {
        post "/api/v1/registrations", params: { password: "securepassword123" }, as: :json
      }.not_to change(User, :count)

      expect(response).to have_http_status(:unprocessable_content)

      json = response.parsed_body
      expect(json["error"]["code"]).to eq("validation_failed")
      expect(json["error"]["details"]["email"]).to include("can't be blank")
    end
  end
end
