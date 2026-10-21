# frozen_string_literal: true

module Api
  module V1
    class SyncController < BaseController
      def show
        query_params = request.query_parameters
        decoded_since = nil

        if query_params.key?("since")
          raw_since = query_params["since"]
          decoded_since = raw_since.is_a?(String) ? Entries::SyncCursor.decode(raw_since) : nil

          unless decoded_since
            return render_error(
              code: :bad_request,
              message: "Invalid since parameter",
              status: :bad_request,
              details: { param: "since" }
            )
          end
        end

        render json: Entries::Changes.call(user: current_user, since: decoded_since)
      end
    end
  end
end
