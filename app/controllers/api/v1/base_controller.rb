module Api
  module V1
    class BaseController < ActionController::API
      private

      def render_validation_error(record)
        render json: {
          error: {
            code: "validation_failed",
            message: "Validation failed",
            details: record.errors.as_json
          }
        }, status: :unprocessable_content
      end
    end
  end
end
