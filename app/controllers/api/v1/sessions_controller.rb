module Api
  module V1
    class SessionsController < ApplicationController

      def create
        user = User.find_by(email: session_params[:email]&.strip&.downcase)

        if user&.authenticate(session_params[:password])
          render json: { api_token: user.api_token }, status: :ok
        else
          render json: { error: "Invalid email or password" }, status: :unauthorized
        end
      end

      private

      def session_params
        params.require(:session).permit(:email, :password)
      end
    end
  end
end
