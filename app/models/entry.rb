class Entry < ApplicationRecord
  belongs_to :feed
  has_many :entry_states, dependent: :destroy

  validates :guid, presence: true, uniqueness: { scope: :feed_id }
  validates :url, presence: true
end
