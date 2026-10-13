# frozen_string_literal: true

class SubscriptionPresenter
  def initialize(subscription, unread_count: nil)
    @subscription = subscription
    @feed = subscription.feed
    @unread_count = unread_count
  end

  def as_json(*)
    {
      id: @subscription.id.to_s,
      title: @feed.title.presence || @feed.url,
      custom_title: @subscription.custom_title,
      url: @feed.url,
      site_url: @feed.site_url,
      unread_count: unread_count,
      status: @feed.status,
      last_fetched_at: @feed.last_fetched_at&.iso8601
    }
  end

  private

  def unread_count
    @unread_count ||= compute_unread_count
  end

  def compute_unread_count
    Entry.unread_counts_for(@subscription.user_id, @subscription.feed_id)[@subscription.feed_id] || 0
  end
end
