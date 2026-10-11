module Authenticatable
  extend ActiveSupport::Concern

  included do
    before_action :authenticate!
  end

  private

  attr_reader :current_user, :current_api_token

  def authenticate!
    raw_token = extract_bearer_token
    return render_unauthorized unless raw_token

    token = ApiToken.active.includes(:user).find_by(token_digest: ApiToken.digest(raw_token))
    return render_unauthorized unless token&.user

    @current_api_token = token
    @current_user = token.user
    @current_api_token.touch_last_used_at!
  end

  def extract_bearer_token
    header = request.headers["Authorization"]
    return if header.blank?

    parts = header.strip.split(/\s+/)
    return unless parts.length == 2 && parts[0].casecmp?("bearer") && parts[1].present?

    parts[1]
  end

  def render_unauthorized
    response.headers["WWW-Authenticate"] = "Bearer"
    render json: {
      error: {
        code: "unauthorized",
        message: "Unauthorized",
        details: {}
      }
    }, status: :unauthorized
  end
end
