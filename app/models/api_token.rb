class ApiToken < ApplicationRecord
  belongs_to :user

  TOKEN_PREFIX = "cyn_"
  LAST_USED_AT_THROTTLE = 1.hour

  scope :active, -> { where(revoked_at: nil) }

  validates :token_digest, presence: true, uniqueness: true
  validates :name, presence: true, length: { maximum: 100 }

  def self.digest(token)
    Digest::SHA256.hexdigest(token)
  end

  def self.issue!(user:, name:)
    raw_token = "#{TOKEN_PREFIX}#{SecureRandom.urlsafe_base64(32)}"
    token = create!(
      user: user,
      name: name,
      token_digest: digest(raw_token)
    )
    [ token, raw_token ]
  end

  def touch_last_used_at!
    return if last_used_at.present? && last_used_at >= LAST_USED_AT_THROTTLE.ago

    update_columns(last_used_at: Time.current)
  end
end
