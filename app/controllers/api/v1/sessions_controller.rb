module Api
  module V1
    class SessionsController < BaseController
      skip_before_action :authenticate!, only: :create

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
