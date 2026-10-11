module Api
  module V1
    class ErrorsController < BaseController
      skip_before_action :authenticate!

      def not_found
        render_not_found
      end
    end
  end
end
