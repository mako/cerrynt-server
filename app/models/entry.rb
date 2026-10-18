# frozen_string_literal: true

class Entry < ApplicationRecord
  belongs_to :feed
  has_many :entry_states, dependent: :destroy

  validates :guid, presence: true, uniqueness: { scope: :feed_id }
  validates :url, presence: true
  validates :published_at, presence: true

  def self.unread_counts_for(user_or_id, feed_ids)
    user_id = user_or_id.is_a?(User) ? user_or_id.id : user_or_id
    ids = Array(feed_ids)
    return {} if ids.empty?

    join_sql = sanitize_sql_array([
      "LEFT JOIN entry_states ON entry_states.entry_id = entries.id AND entry_states.user_id = ?",
      user_id
    ])

    where(feed_id: ids)
      .joins(join_sql)
      .where(entry_states: { read_at: nil })
      .group(:feed_id)
      .count
  end
end
