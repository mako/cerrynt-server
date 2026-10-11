module Api
  module V1
    class BaseController < ActionController::API
      private

      def render_validation_error(record, rename: {})
        details = record.errors.as_json.stringify_keys
        rename.each do |from, to|
          details[to.to_s] = details.delete(from.to_s) if details.key?(from.to_s)
        end

        render json: {
          error: {
            code: "validation_failed",
            message: "Validation failed",
            details: details
          }
        }, status: :unprocessable_content
      end
    end
  end
end
