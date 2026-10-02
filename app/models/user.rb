class User < ApplicationRecord
  has_secure_password
  has_secure_token :api_token

  has_many :feeds, dependent: :destroy
  has_many :items, through: :feeds

  normalizes :email, with: ->(email) { email.strip.downcase }
  validates :email, presence: true,
                    uniqueness: { case_sensitive: false },
                    format: { with: URI::MailTo::EMAIL_REGEXP }
end
