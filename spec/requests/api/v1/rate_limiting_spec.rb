require 'rails_helper'

RSpec.describe "Rate limiting", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  let!(:user) { create(:user, email: "user@example.com", password: "securepassword123") }
  let!(:other_user) { create(:user, email: "other@example.com", password: "securepassword123") }

  def register(email, ip: "192.0.2.1", password: "securepassword123")
    post "/api/v1/registrations",
         params: { email: email, password: password },
         headers: { "REMOTE_ADDR" => ip },
         as: :json
  end

  def login(email, ip: "192.0.2.1", password: "securepassword123", device: "laptop-cli")
    params = { password: password, device_name: device }
    params[:email] = email if email
    post "/api/v1/sessions",
         params: params,
         headers: { "REMOTE_ADDR" => ip },
         as: :json
  end

  describe "POST /api/v1/registrations" do
    let(:ip) { "192.0.2.1" }

    it "limits requests to 10 per hour per IP and sets Retry-After header" do
      10.times do |i|
        register("newuser#{i}@example.com", ip: ip)
        expect(response).to have_http_status(:created)
      end

      register("newuser10@example.com", ip: ip)

      expect(response).to have_http_status(:too_many_requests)
      expect(response.headers["Retry-After"]).to eq("3600")

      json = response.parsed_body
      expect(json).to eq({
        "error" => {
          "code" => "rate_limited",
          "message" => "Too many requests. Please try again later.",
          "details" => {}
        }
      })
    end

    it "does not limit requests from a different IP address" do
      10.times do |i|
        register("newuser#{i}@example.com", ip: ip)
        expect(response).to have_http_status(:created)
      end

      register("different_ip_user@example.com", ip: "192.0.2.2")
      expect(response).to have_http_status(:created)
    end

    it "resets the IP counter after the 1 hour window passes" do
      10.times do |i|
        register("newuser#{i}@example.com", ip: ip)
        expect(response).to have_http_status(:created)
      end

      register("newuser10@example.com", ip: ip)
      expect(response).to have_http_status(:too_many_requests)

      travel 1.hour + 1.second

      register("newuser_after_window@example.com", ip: ip)
      expect(response).to have_http_status(:created)
    end
  end

  describe "POST /api/v1/sessions" do
    describe "per-IP limit (20 requests per 5 minutes)" do
      let(:ip) { "192.0.2.10" }

      it "limits login requests to 20 per 5 minutes per IP with Retry-After 300" do
        20.times do |i|
          u = create(:user, email: "ipuser#{i}@example.com", password: "securepassword123")
          login(u.email, ip: ip, device: "dev-#{i}")
          expect(response).to have_http_status(:created)
        end

        u20 = create(:user, email: "ipuser20@example.com", password: "securepassword123")
        login(u20.email, ip: ip, device: "dev-20")

        expect(response).to have_http_status(:too_many_requests)
        expect(response.headers["Retry-After"]).to eq("300")

        json = response.parsed_body
        expect(json).to eq({
          "error" => {
            "code" => "rate_limited",
            "message" => "Too many requests. Please try again later.",
            "details" => {}
          }
        })
      end

      it "does not limit login requests from a different IP address" do
        20.times do |i|
          u = create(:user, email: "ipuser#{i}@example.com", password: "securepassword123")
          login(u.email, ip: ip, device: "dev-#{i}")
          expect(response).to have_http_status(:created)
        end

        diff_user = create(:user, email: "ipuser_diff@example.com", password: "securepassword123")
        login(diff_user.email, ip: "192.0.2.11", device: "dev-diff-ip")

        expect(response).to have_http_status(:created)
      end

      it "resets the IP counter after the 5 minute window passes" do
        20.times do |i|
          u = create(:user, email: "ipuser#{i}@example.com", password: "securepassword123")
          login(u.email, ip: ip, device: "dev-#{i}")
          expect(response).to have_http_status(:created)
        end

        u20 = create(:user, email: "ipuser20@example.com", password: "securepassword123")
        login(u20.email, ip: ip, device: "dev-20")
        expect(response).to have_http_status(:too_many_requests)

        travel 5.minutes + 1.second

        after_user = create(:user, email: "ipuser_after@example.com", password: "securepassword123")
        login(after_user.email, ip: ip, device: "dev-after")
        expect(response).to have_http_status(:created)
      end
    end

    describe "per-email limit (10 requests per 15 minutes across different IPs)" do
      it "limits login requests to 10 per 15 minutes per normalized email and sets Retry-After 900" do
        10.times do |i|
          login(user.email, ip: "198.51.100.#{i}", device: "dev-#{i}")
          expect(response).to have_http_status(:created)
        end

        login(user.email, ip: "198.51.100.99", device: "dev-10")

        expect(response).to have_http_status(:too_many_requests)
        expect(response.headers["Retry-After"]).to eq("900")

        json = response.parsed_body
        expect(json).to eq({
          "error" => {
            "code" => "rate_limited",
            "message" => "Too many requests. Please try again later.",
            "details" => {}
          }
        })
      end

      it "does not affect a different email address" do
        10.times do |i|
          login(user.email, ip: "198.51.100.#{i}", device: "dev-#{i}")
          expect(response).to have_http_status(:created)
        end

        login(other_user.email, ip: "198.51.100.99", device: "dev-other")
        expect(response).to have_http_status(:created)
      end

      it "shares the counter across whitespace and case variations of the email" do
        5.times do |i|
          login("  #{user.email}  ", ip: "198.51.100.#{i}", device: "dev-#{i}")
          expect(response).to have_http_status(:created)
        end

        5.times do |i|
          login(user.email.upcase, ip: "198.51.100.#{i + 10}", device: "dev-up-#{i}")
          expect(response).to have_http_status(:created)
        end

        login(user.email, ip: "198.51.100.99", device: "dev-final")
        expect(response).to have_http_status(:too_many_requests)
      end

      it "does not apply per-email limit when email parameter is missing" do
        15.times do |i|
          login(nil, ip: "198.51.100.#{i}", device: "dev-#{i}")
          expect(response).to have_http_status(:unauthorized)
        end
      end

      it "resets the email counter after the 15 minute window passes" do
        10.times do |i|
          login(user.email, ip: "198.51.100.#{i}", device: "dev-#{i}")
          expect(response).to have_http_status(:created)
        end

        login(user.email, ip: "198.51.100.99", device: "dev-10")
        expect(response).to have_http_status(:too_many_requests)

        travel 15.minutes + 1.second

        login(user.email, ip: "198.51.100.99", device: "dev-after")
        expect(response).to have_http_status(:created)
      end
    end
  end

  describe "unaffected endpoints and limit isolation" do
    let(:ip) { "192.0.2.50" }

    it "does not rate limit GET /api/v1/me" do
      _token_record, raw_token = ApiToken.issue!(user: user, name: "test-device")
      auth_headers = { "Authorization" => "Bearer #{raw_token}", "REMOTE_ADDR" => ip }

      25.times do
        get "/api/v1/me", headers: auth_headers
        expect(response).to have_http_status(:ok)
      end
    end

    it "isolates registration and login counters" do
      10.times do |i|
        register("reg#{i}@example.com", ip: ip)
        expect(response).to have_http_status(:created)
      end

      # 11th registration from this IP is rate limited
      register("reg_blocked@example.com", ip: ip)
      expect(response).to have_http_status(:too_many_requests)

      # Login from the same IP still succeeds
      login(user.email, ip: ip, device: "login-device")
      expect(response).to have_http_status(:created)
    end
  end
end
