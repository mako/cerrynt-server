# frozen_string_literal: true

module Api
  module V1
    class OpmlController < BaseController
      USER_LIMIT = 5
      USER_WINDOW = 10.minutes

      rate_limit to: USER_LIMIT, within: USER_WINDOW,
                 by: -> { current_user.id },
                 name: "opml-import-user",
                 with: -> { render_rate_limited(USER_WINDOW) },
                 only: :import

      def import
        file = params[:file]
        unless file.is_a?(ActionDispatch::Http::UploadedFile)
          return render_error(
            code: :bad_request,
            message: "Missing or invalid file parameter",
            status: :bad_request,
            details: { param: "file" }
          )
        end

        body = file.read(Opml::Parser::MAX_BODY_BYTES + 1) || ""
        parse_result = Opml::Parser.parse(body)

        unless parse_result.ok?
          return render_error(
            code: :invalid_opml,
            message: "Invalid OPML file",
            status: :unprocessable_content,
            details: { reason: parse_result.reason.to_s }
          )
        end

        import_result = Opml::Import.call(user: current_user, outlines: parse_result.outlines)

        render json: {
          imported: import_result.imported,
          skipped: import_result.skipped,
          errors: import_result.errors
        }, status: :ok
      end

      def export
        opml_data = Opml::Export.call(user: current_user)

        send_data opml_data,
                  type: "application/xml; charset=utf-8",
                  disposition: "attachment",
                  filename: "cerrynt-subscriptions.opml"
      end
    end
  end
end
