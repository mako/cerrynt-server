module Api
  module V1
    class RegistrationsController < BaseController
      IP_LIMIT = 10
      IP_WINDOW = 1.hour

      skip_before_action :authenticate!, only: :create

      rate_limit to: IP_LIMIT, within: IP_WINDOW,
                 by: -> { request.remote_ip },
                 name: "registrations-ip",
                 with: -> { render_rate_limited(IP_WINDOW) },
                 only: :create

      def create
        user = User.new(registration_params)

        if user.save
          render json: { user: user.to_api_h }, status: :created
        else
          render_validation_error(user)
        end
      end

      private

      def registration_params
        params.permit(:email, :password)
      end
    end
  end
end
