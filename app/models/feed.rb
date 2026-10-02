class Feed < ApplicationRecord
  belongs_to :user
  has_many :items, dependent: :destroy

  normalizes :url, with: ->(url) { url.strip }

  validates :url, presence: true,
                  format: { with: URI::DEFAULT_PARSER.make_regexp(%w[http https]) },
                  uniqueness: { scope: :user_id }
end
