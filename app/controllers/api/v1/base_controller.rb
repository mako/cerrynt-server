module Api
  module V1
    class BaseController < ApplicationController
      before_action :authenticate_user!

      private

      def authenticate_user!
        token = request.headers["Authorization"]&.remove("Bearer ")
        @current_user = User.find_by(api_token: token) if token.present?

        render json: { error: "Unauthorized" }, status: :unauthorized unless @current_user
      end

      attr_reader :current_user
    end
  end
end
