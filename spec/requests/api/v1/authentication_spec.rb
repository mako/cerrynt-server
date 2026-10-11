require 'rails_helper'

RSpec.describe "Token Authentication", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  let(:user) { create(:user, password: "securepassword123") }
  let(:session) { ApiToken.issue!(user: user, name: "laptop-cli") }
  let(:token_record) { session[0] }
  let(:raw_token) { session[1] }

  describe "unauthorized cases" do
    it "returns identical 401 response with WWW-Authenticate header across all failure modes" do
      revoked_token = ApiToken.issue!(user: user, name: "revoked-device")
      revoked_token[0].update_columns(revoked_at: Time.current)

      headers_list = [
        {}, # no header
        { "Authorization" => "Basic #{raw_token}" }, # wrong scheme
        { "Authorization" => "Bearer " }, # empty token
        { "Authorization" => "Bearer" }, # missing token
        { "Authorization" => "Bearer token1 token2" }, # multiple tokens
        { "Authorization" => "Bearer cyn_unknown_token_value_that_does_not_exist" }, # unknown token
        { "Authorization" => "Bearer #{revoked_token[1]}" } # revoked token
      ]

      responses = headers_list.map do |headers|
        delete "/api/v1/session", headers: headers
        expect(response).to have_http_status(:unauthorized)
        expect(response.headers["WWW-Authenticate"]).to eq("Bearer")
        response.parsed_body
      end

      expected_body = {
        "error" => {
          "code" => "unauthorized",
          "message" => "Unauthorized",
          "details" => {}
        }
      }

      responses.each do |body|
        expect(body).to eq(expected_body)
      end
    end
  end

  describe "scheme case-insensitivity" do
    it "accepts lowercase 'bearer'" do
      delete "/api/v1/session", headers: { "Authorization" => "bearer #{raw_token}" }
      expect(response).to have_http_status(:no_content)
    end
  end

  describe "last_used_at throttling" do
    it "sets last_used_at on first use, throttles updates within 1 hour, and updates after 2 hours" do
      freeze_time do
        expect(token_record.last_used_at).to be_nil

        # First use sets last_used_at
        delete "/api/v1/session", headers: { "Authorization" => "Bearer #{raw_token}" }
        expect(token_record.reload.last_used_at).to eq(Time.current)

        initial_time = Time.current

        # Re-activate token for testing subsequent calls
        token_record.update_columns(revoked_at: nil)

        # Second use within the hour does not update last_used_at
        travel 30.minutes
        delete "/api/v1/session", headers: { "Authorization" => "Bearer #{raw_token}" }
        expect(token_record.reload.last_used_at).to eq(initial_time)

        token_record.update_columns(revoked_at: nil)

        # Third use after 2 hours updates last_used_at
        travel 90.minutes # now 2 hours after initial_time
        delete "/api/v1/session", headers: { "Authorization" => "Bearer #{raw_token}" }
        expect(token_record.reload.last_used_at).to eq(Time.current)
      end
    end
  end

  describe "unprotected endpoints" do
    it "allows POST /api/v1/registrations without Authorization header" do
      post "/api/v1/registrations",
           params: { email: "unprotected_reg@example.com", password: "securepassword123" },
           as: :json

      expect(response).to have_http_status(:created)
    end

    it "allows POST /api/v1/sessions without Authorization header" do
      post "/api/v1/sessions",
           params: { email: user.email, password: "securepassword123", device_name: "test-device" },
           as: :json

      expect(response).to have_http_status(:created)
    end
  end
end
