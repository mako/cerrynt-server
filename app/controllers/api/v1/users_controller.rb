module Api
  module V1
    class UsersController < BaseController
      def show
        render json: UserSerializer.new(current_user)
      end
    end
  end
end
