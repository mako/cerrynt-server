require 'rails_helper'

RSpec.describe "API v1 Route Protection Guard", type: :request do
  let(:public_routes) do
    [ "api/v1/registrations#create", "api/v1/sessions#create" ]
  end

  let(:api_routes) do
    Rails.application.routes.routes.select do |route|
      route.path.spec.to_s.start_with?("/api/v1")
    end
  end

  let(:protected_routes) do
    api_routes.reject do |route|
      action = "#{route.defaults[:controller]}##{route.defaults[:action]}"
      public_routes.include?(action) || route.path.spec.to_s.include?("*unmatched")
    end
  end

  it "verifies that the guard finds known protected endpoints" do
    route_signatures = protected_routes.map do |route|
      verb = route.verb
      path = route.path.spec.to_s.sub("(.:format)", "")
      "#{verb} #{path}"
    end

    expect(route_signatures).to include("GET /api/v1/me", "DELETE /api/v1/session", "GET /api/v1/entries", "GET /api/v1/sync")
  end

  it "requires authentication for all non-whitelisted /api/v1 routes" do
    expect(protected_routes).not_to be_empty

    protected_routes.each do |route|
      verb = route.verb.downcase.to_sym
      path = route.path.spec.to_s.sub("(.:format)", "")

      public_send(verb, path)

      expect(response).to have_http_status(:unauthorized),
                          "Expected #{route.verb} #{path} to require authentication, but got #{response.status}"
      expect(response.headers["WWW-Authenticate"]).to eq("Bearer")
      expect(response.parsed_body["error"]["code"]).to eq("unauthorized")
    end
  end
end
