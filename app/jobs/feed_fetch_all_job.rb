class FeedFetchAllJob < ApplicationJob
  queue_as :default

  def perform
    Feed.find_each { |feed| FeedFetchJob.perform_later(feed) }
  end
end
