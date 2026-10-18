# frozen_string_literal: true

class EntrySummaryPresenter
  def initialize(entry, subscription_id:)
    @entry = entry
    @subscription_id = subscription_id
  end

  def as_json(*)
    {
      id: @entry.id.to_s,
      subscription_id: @subscription_id.to_s,
      title: @entry.title,
      author: @entry.author,
      url: @entry.url,
      published_at: @entry.published_at.utc.iso8601,
      read: @entry.state_read_at.present?,
      starred: @entry.state_starred_at.present?
    }
  end
end
