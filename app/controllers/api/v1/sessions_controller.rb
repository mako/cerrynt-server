module Api
  module V1
    class SessionsController < BaseController
      IP_LIMIT = 20
      IP_WINDOW = 5.minutes
      EMAIL_LIMIT = 10
      EMAIL_WINDOW = 15.minutes

      skip_before_action :authenticate!, only: :create

      rate_limit to: IP_LIMIT, within: IP_WINDOW,
                 by: -> { request.remote_ip },
                 name: "sessions-ip",
                 with: -> { render_rate_limited(IP_WINDOW) },
                 only: :create

      rate_limit to: EMAIL_LIMIT, within: EMAIL_WINDOW,
                 by: -> { Digest::SHA256.hexdigest(params[:email].to_s.strip.downcase) },
                 if: -> { params[:email].present? },
                 name: "sessions-email",
                 with: -> { render_rate_limited(EMAIL_WINDOW) },
                 only: :create

      def create
        user = User.authenticate_by(email: session_params[:email], password: session_params[:password])
        return render_invalid_credentials unless user

        _token, raw_token = ApiToken.issue!(user: user, name: session_params[:device_name])
        render json: { token: raw_token, user: user.to_api_h }, status: :created
      rescue ActiveRecord::RecordInvalid => e
        render_validation_error(e.record, rename: { "name" => "device_name" })
      end

      def destroy
        current_api_token.update_columns(revoked_at: Time.current)
        head :no_content
      end

      private

      def session_params
        params.permit(:email, :password, :device_name)
      end

      def render_invalid_credentials
        render json: {
          error: {
            code: "invalid_credentials",
            message: "Wrong email or password",
            details: {}
          }
        }, status: :unauthorized
      end
    end
  end
end
