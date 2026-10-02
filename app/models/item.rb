class Item < ApplicationRecord
  belongs_to :feed

  validates :guid, presence: true, uniqueness: { scope: :feed_id }
  validates :url, format: { with: URI::DEFAULT_PARSER.make_regexp(%w[http https]) }, allow_blank: true
end
