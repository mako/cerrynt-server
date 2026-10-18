# frozen_string_literal: true

class EntrySummaryPresenter
  def initialize(entry, subscription_id:, read: nil, starred: nil)
    @entry = entry
    @subscription_id = subscription_id
    @read = read
    @starred = starred
  end

  def as_json(*)
    {
      id: @entry.id.to_s,
      subscription_id: @subscription_id.to_s,
      title: @entry.title,
      author: @entry.author,
      url: @entry.url,
      summary: @entry.summary,
      published_at: @entry.published_at&.utc&.iso8601,
      read: read?,
      starred: starred?
    }
  end

  private

  def read?
    return @read unless @read.nil?

    @entry.respond_to?(:state_read_at) ? @entry.state_read_at.present? : false
  end

  def starred?
    return @starred unless @starred.nil?

    @entry.respond_to?(:state_starred_at) ? @entry.state_starred_at.present? : false
  end
end
