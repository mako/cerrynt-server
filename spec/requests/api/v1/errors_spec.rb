require 'rails_helper'

RSpec.describe "Shared Error Handling", type: :request do
  describe "malformed JSON body" do
    it "returns 400 bad_request and does not echo the input" do
      post "/api/v1/registrations",
           params: "not a valid json {",
           headers: { "CONTENT_TYPE" => "application/json" }

      expect(response).to have_http_status(:bad_request)

      json = response.parsed_body
      expect(json).to eq({
        "error" => {
          "code" => "bad_request",
          "message" => "Bad request",
          "details" => {}
        }
      })
      expect(response.body).not_to include("not a valid json")
    end
  end

  describe "unknown routes under /api/v1" do
    it "returns 404 not_found JSON format" do
      get "/api/v1/unknown_route_path"

      expect(response).to have_http_status(:not_found)

      json = response.parsed_body
      expect(json).to eq({
        "error" => {
          "code" => "not_found",
          "message" => "Resource not found",
          "details" => {}
        }
      })
    end
  end

  describe "health check endpoint" do
    it "GET /up returns 200" do
      get "/up"
      expect(response).to have_http_status(:ok)
    end
  end
end
