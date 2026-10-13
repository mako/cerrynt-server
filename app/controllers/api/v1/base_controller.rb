module Api
  module V1
    class BaseController < ActionController::API
      include Authenticatable

      rescue_from ActiveRecord::RecordNotFound, with: :render_not_found
      rescue_from ActionDispatch::Http::Parameters::ParseError, ActionController::ParameterMissing, with: :render_bad_request

      private

      def render_error(code:, message:, status:, details: {})
        render json: {
          error: {
            code: code.to_s,
            message: message,
            details: details
          }
        }, status: status
      end

      def render_not_found
        render json: {
          error: {
            code: "not_found",
            message: "Resource not found",
            details: {}
          }
        }, status: :not_found
      end

      def render_bad_request
        render json: {
          error: {
            code: "bad_request",
            message: "Bad request",
            details: {}
          }
        }, status: :bad_request
      end

      def render_rate_limited(retry_after)
        response.headers["Retry-After"] = retry_after.to_i.to_s
        render json: {
          error: {
            code: "rate_limited",
            message: "Too many requests. Please try again later.",
            details: {}
          }
        }, status: :too_many_requests
      end

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
