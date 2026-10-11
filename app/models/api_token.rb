class ApiToken < ApplicationRecord
  belongs_to :user

  TOKEN_PREFIX = "cyn_"

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
end
