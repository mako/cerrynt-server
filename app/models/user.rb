class User < ApplicationRecord
  has_secure_password

  has_many :api_tokens, dependent: :destroy
  has_many :subscriptions, dependent: :destroy
  has_many :feeds, through: :subscriptions
  has_many :entry_states, dependent: :destroy

  normalizes :email, with: ->(email) { email.strip.downcase }

  validates :email, presence: true,
                    uniqueness: { case_sensitive: false },
                    format: { with: URI::MailTo::EMAIL_REGEXP }
  validates :plan, inclusion: { in: %w[free pro] }
end
