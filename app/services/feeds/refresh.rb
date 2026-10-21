# frozen_string_literal: true

require "digest"
require "uri"

module Feeds
  class Refresh
    Result = Data.define(:success, :error, :message, :created, :updated, :skipped, :deferred, :feed) do
      def initialize(success:, error:, message:, created:, updated:, skipped:, feed:, deferred: 0)
        super(
          success: success,
          error: error,
          message: message,
          created: created,
          updated: updated,
          skipped: skipped,
          deferred: deferred,
          feed: feed
        )
      end

      def ok?
        success
      end
    end

    FeedMetadata = Data.define(:etag, :last_modified, :title, :site_url)

    Prepared = Data.define(:feed_metadata, :entries, :skipped, :deferred) do
      delegate :etag, :last_modified, :title, :site_url, to: :feed_metadata
    end

    NormalizedEntry = Data.define(
      :guid,
      :url,
      :title,
      :author,
      :summary,
      :content,
      :raw_published_at
    )

    MAX_URL_LENGTH = 2048
    MAX_TITLE_LENGTH = 500
    MAX_AUTHOR_LENGTH = 255
    MAX_GUID_LENGTH = 500
    BACKGROUND_SANITIZE_BUDGET = 1_000_000

    class << self
      def call(feed, fetcher: Feeds::Fetcher.method(:call), budget: BACKGROUND_SANITIZE_BUDGET)
        fetch_result = fetcher.call(feed.url)

        unless fetch_result.ok?
          return Result.new(
            success: false,
            error: fetch_result.error,
            message: fetch_result.message,
            created: 0,
            updated: 0,
            skipped: 0,
            deferred: 0,
            feed: feed
          )
        end

        prepared = prepare(fetch_result, budget: budget)
        persist(feed, prepared)
      end

      def prepare(fetch_result, budget: BACKGROUND_SANITIZE_BUDGET)
        raw_entries = fetch_result.feed&.entries || []
        valid_entries, skipped_count, deferred_count = process_and_filter_entries(raw_entries, budget: budget)
        feed_metadata = extract_feed_metadata(fetch_result)

        Prepared.new(
          feed_metadata: feed_metadata,
          entries: valid_entries.freeze,
          skipped: skipped_count,
          deferred: deferred_count
        )
      end

      def persist(feed, prepared)
        created_count = 0
        updated_count = 0
        valid_entries = prepared.entries

        ApplicationRecord.write_transaction do |now|
          guids = valid_entries.map(&:guid)
          existing_entries = guids.any? ? feed.entries.where(guid: guids).index_by(&:guid) : {}

          new_records = []

          valid_entries.each do |item|
            existing = existing_entries[item.guid]

            if existing
              changes = compute_changes(existing, item, now)
              if changes.any?
                changes[:updated_at] = now
                existing.update!(changes)
                updated_count += 1
              end
            else
              new_records << build_new_entry_hash(feed.id, item, now)
            end
          end

          if new_records.any?
            insert_result = Entry.insert_all(new_records, unique_by: [ :feed_id, :guid ])
            created_count = insert_result.count
          end

          update_feed_metadata!(feed, prepared, now)
        end

        Result.new(
          success: true,
          error: nil,
          message: nil,
          created: created_count,
          updated: updated_count,
          skipped: prepared.skipped,
          deferred: prepared.deferred,
          feed: feed
        )
      end

      private

      def process_and_filter_entries(raw_entries, budget:)
        seen_guids = Set.new
        valid_entries = []
        skipped = 0
        deferred = 0
        used_budget = 0
        budget_exceeded = false

        raw_entries.each do |entry|
          clean_guid = entry.guid.to_s.scrub.delete("\0").strip
          if clean_guid.empty?
            if valid_http_url?(entry.url)
              clean_guid = entry.url.to_s.scrub.delete("\0").strip
            else
              skipped += 1
              next
            end
          end

          normalized_guid = clean_guid.length > MAX_GUID_LENGTH ? Digest::SHA256.hexdigest(clean_guid) : clean_guid

          # Within one batch, de-duplicate by guid (first wins)
          next if seen_guids.include?(normalized_guid)

          seen_guids.add(normalized_guid)

          candidate_url = normalize_string(entry.url)
          entry_url =
            if valid_http_url?(candidate_url)
              candidate_url
            elsif valid_http_url?(clean_guid)
              clean_guid
            end

          if entry_url.nil?
            skipped += 1
            next
          end

          raw_summary = normalize_content(entry.summary)
          raw_content = normalize_content(entry.content)

          summary_chars = raw_summary.blank? ? 0 : [ raw_summary.length, Feeds::ContentSanitizer::MAX_INPUT_CHARS ].min
          content_chars = raw_content.blank? ? 0 : [ raw_content.length, Feeds::ContentSanitizer::MAX_INPUT_CHARS ].min
          entry_chars = summary_chars + content_chars

          if budget_exceeded || (valid_entries.any? && (used_budget + entry_chars > budget))
            budget_exceeded = true
            deferred += 1
            next
          end

          used_budget += entry_chars

          summary = Feeds::ContentSanitizer.call(raw_summary, base_url: entry_url)
          content = Feeds::ContentSanitizer.call(raw_content, base_url: entry_url)

          valid_entries << NormalizedEntry.new(
            guid: normalized_guid,
            url: entry_url,
            title: normalize_string(entry.title, max_length: MAX_TITLE_LENGTH),
            author: normalize_string(entry.author, max_length: MAX_AUTHOR_LENGTH),
            summary: summary,
            content: content,
            raw_published_at: entry.published_at
          )
        end

        [ valid_entries, skipped, deferred ]
      end

      def extract_feed_metadata(fetch_result)
        cleaned_title = nil
        if fetch_result.feed&.title.present?
          candidate_title = normalize_string(fetch_result.feed.title, max_length: MAX_TITLE_LENGTH)
          cleaned_title = candidate_title if candidate_title.present?
        end

        cleaned_site_url = nil
        if fetch_result.feed&.site_url.present?
          candidate_site_url = normalize_string(fetch_result.feed.site_url)
          cleaned_site_url = candidate_site_url if valid_http_url?(candidate_site_url)
        end

        FeedMetadata.new(
          etag: fetch_result.etag,
          last_modified: fetch_result.last_modified,
          title: cleaned_title,
          site_url: cleaned_site_url
        )
      end

      def compute_changes(existing, item, now)
        changes = {}
        changes[:url] = item.url if existing.url != item.url
        changes[:title] = item.title if existing.title != item.title
        changes[:author] = item.author if existing.author != item.author
        changes[:summary] = item.summary if existing.summary != item.summary
        changes[:content] = item.content if existing.content != item.content

        if item.raw_published_at.present? && item.raw_published_at <= now && !times_equal?(existing.published_at, item.raw_published_at)
          changes[:published_at] = item.raw_published_at
        end

        changes
      end

      def build_new_entry_hash(feed_id, item, now)
        published_at =
          if item.raw_published_at.present?
            item.raw_published_at > now ? now : item.raw_published_at
          else
            now
          end

        {
          feed_id: feed_id,
          guid: item.guid,
          url: item.url,
          title: item.title,
          author: item.author,
          summary: item.summary,
          content: item.content,
          published_at: published_at,
          created_at: now,
          updated_at: now
        }
      end

      def update_feed_metadata!(feed, prepared, now)
        metadata = prepared.feed_metadata
        has_deferred = prepared.deferred > 0
        feed_attributes = {
          etag: has_deferred ? nil : metadata.etag,
          last_modified: has_deferred ? nil : metadata.last_modified,
          last_fetched_at: now,
          last_success_at: now,
          consecutive_failures: 0,
          status: "active",
          updated_at: now
        }

        feed_attributes[:title] = metadata.title if metadata.title.present?
        feed_attributes[:site_url] = metadata.site_url if metadata.site_url.present?

        feed.update!(feed_attributes)
      end

      def normalize_string(str, max_length: nil)
        return nil if str.nil?

        cleaned = str.to_s.scrub.delete("\0").strip
        max_length ? cleaned[0, max_length] : cleaned
      end

      def normalize_content(str)
        return nil if str.nil?

        str.to_s.scrub.delete("\0")
      end

      def valid_http_url?(url_str)
        return false if url_str.blank?
        return false if url_str.length > MAX_URL_LENGTH

        uri = URI.parse(url_str.strip)
        (uri.is_a?(URI::HTTP) || uri.is_a?(URI::HTTPS)) &&
          uri.host.present? &&
          uri.userinfo.blank? &&
          uri.user.blank? &&
          uri.password.blank?
      rescue URI::InvalidURIError
        false
      end

      def times_equal?(time1, time2)
        return true if time1.nil? && time2.nil?
        return false if time1.nil? || time2.nil?

        time1.to_i == time2.to_i
      end
    end
  end
end
