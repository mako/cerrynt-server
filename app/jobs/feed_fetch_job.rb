class FeedFetchJob < ApplicationJob
  require "net/http"
  require "uri"

  queue_as :default

  HTTP_OPEN_TIMEOUT = 5
  HTTP_READ_TIMEOUT = 10
  MAX_REDIRECTS = 3

  def perform(feed)
    xml = fetch_xml(feed.url)
    return if xml.nil?

    parsed_feed = Feedjira.parse(xml)
    parsed_feed.entries.each { |entry| create_item_from_entry(feed, entry) }

    feed.update!(
      title: feed.title.presence || parsed_feed.title,
      last_fetched_at: Time.current
    )
  rescue Feedjira::NoParserAvailable => e
    Rails.logger.error("[FeedFetchJob] No parser available for feed ##{feed.id}: #{e.message}")
  rescue => e
    Rails.logger.error(
      "[FeedFetchJob] Failed to fetch feed ##{feed.id} (#{feed.url}): #{e.class} - #{e.message}"
    )
  end

  private

  def fetch_xml(url, redirects_left = MAX_REDIRECTS)
    uri = URI.parse(url)

    response = Net::HTTP.start(
      uri.host, uri.port,
      use_ssl: uri.scheme == "https",
      open_timeout: HTTP_OPEN_TIMEOUT,
      read_timeout: HTTP_READ_TIMEOUT
    ) { |http| http.get(uri.request_uri, { "User-Agent" => "Cerrynt/1.0 (+https://github.com/mako/cerrynt-api)" }) }

    case response
    when Net::HTTPSuccess
      response.body
    when Net::HTTPRedirection
      return nil if redirects_left.zero?
      fetch_xml(response["location"], redirects_left - 1)
    else
      Rails.logger.warn("[FeedFetchJob] HTTP #{response.code} fetching #{url}")
      nil
    end
  end

  def create_item_from_entry(feed, entry)
    guid = entry.entry_id.presence || entry.url
    return if guid.blank?

    item = feed.items.find_or_initialize_by(guid: guid)
    return if item.persisted?

    item.assign_attributes(
      title: entry.title,
      url: entry.url,
      summary: entry.summary,
      published_at: entry.published || Time.current
    )

    item.save!
  rescue ActiveRecord::RecordInvalid => e
    Rails.logger.warn("[FeedFetchJob] Skipped invalid item for feed ##{feed.id}: #{e.message}")
  rescue ActiveRecord::RecordNotUnique
    # another process/job already inserted this guid between find_or_initialize and save,
    # the DB unique index on [feed_id, guid] is the real safety net, this just avoids a crash
  end
end
