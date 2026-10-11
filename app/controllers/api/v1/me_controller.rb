module Api
  module V1
    class MeController < BaseController
      def show
        render json: { user: current_user.to_api_h }
      end
    end
  end
end
