module Api
  module V1
    class RegistrationsController < BaseController
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
