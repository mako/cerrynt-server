# frozen_string_literal: true

module Opml
  class Import
    Result = Data.define(:imported, :skipped, :errors) do
      def ok?
        true
      end
    end

    Candidate = Data.define(:index, :url, :raw_url, :title, :site_url)

    def self.call(user:, outlines:)
      new(user: user, outlines: outlines).call
    end

    def initialize(user:, outlines:)
      @user = user
      @outlines = outlines || []
    end

    def call
      return Result.new(imported: 0, skipped: 0, errors: []) if @outlines.empty?

      pre_errors = []
      seen_urls = Set.new
      candidates = []
      skipped = 0

      @outlines.each_with_index do |outline, idx|
        raw_url = outline[:url]
        cut_url = raw_url.to_s.dup.force_encoding(Encoding::UTF_8).scrub("")[0, Feeds::UrlPolicy::MAX_URL_LENGTH]
        normalized_url = Feeds::UrlPolicy.normalize_and_validate_feed_url(raw_url)

        if normalized_url.nil?
          pre_errors << { index: idx, error: { url: cut_url, code: "invalid_feed_url" } }
        elsif seen_urls.include?(normalized_url)
          skipped += 1
        else
          seen_urls.add(normalized_url)
          site_url = Feeds::UrlPolicy.clean_site_url(outline[:html_url])
          candidates << Candidate.new(
            index: idx,
            url: normalized_url,
            raw_url: cut_url,
            title: outline[:title].presence,
            site_url: site_url
          )
        end
      end

      if candidates.empty?
        sorted_errors = pre_errors.sort_by { |e| e[:index] }.map { |e| e[:error] }
        return Result.new(imported: 0, skipped: skipped, errors: sorted_errors)
      end

      imported = 0
      limit_errors = []

      ApplicationRecord.write_transaction do |now|
        @user.lock!
        current_count = @user.subscriptions.count

        candidate_urls = candidates.map(&:url)
        existing_rows = Feed.joins(
          Feed.sanitize_sql_array([
            "LEFT OUTER JOIN subscriptions ON subscriptions.feed_id = feeds.id AND subscriptions.user_id = ?",
            @user.id
          ])
        ).where(url: candidate_urls).pluck("feeds.url", "feeds.id", "subscriptions.id")

        followed_urls = Set.new
        existing_feed_ids = {}

        existing_rows.each do |url, feed_id, sub_id|
          existing_feed_ids[url] = feed_id
          followed_urls.add(url) if sub_id.present?
        end

        unfollowed_candidates = []
        candidates.each do |candidate|
          if followed_urls.include?(candidate.url)
            skipped += 1
          else
            unfollowed_candidates << candidate
          end
        end

        plan_limit = Plan.max_feeds_for(@user.plan)
        remaining_slots = [ plan_limit - current_count, 0 ].max

        to_subscribe = unfollowed_candidates.first(remaining_slots)
        over_limit = unfollowed_candidates.drop(remaining_slots)

        over_limit.each do |candidate|
          limit_errors << {
            index: candidate.index,
            error: { url: candidate.raw_url, code: "feed_limit_reached" }
          }
        end

        new_feed_records = []
        to_subscribe.each do |candidate|
          next if existing_feed_ids.key?(candidate.url)

          new_feed_records << {
            url: candidate.url,
            title: candidate.title,
            site_url: candidate.site_url,
            next_fetch_at: now,
            status: "active",
            consecutive_failures: 0,
            created_at: now,
            updated_at: now
          }
        end

        if new_feed_records.any?
          Feed.insert_all(
            new_feed_records,
            unique_by: :url,
            record_timestamps: false
          )
        end

        subscribed_urls = to_subscribe.map(&:url)
        all_feed_ids = if subscribed_urls.any?
          Feed.where(url: subscribed_urls).pluck(:url, :id).to_h
        else
          {}
        end

        sub_records = to_subscribe.filter_map do |candidate|
          feed_id = all_feed_ids[candidate.url]
          next unless feed_id

          {
            user_id: @user.id,
            feed_id: feed_id,
            custom_title: nil,
            created_at: now,
            updated_at: now
          }
        end

        insert_result = if sub_records.any?
          Subscription.insert_all(
            sub_records,
            unique_by: [ :user_id, :feed_id ],
            record_timestamps: false
          )
        end

        really_inserted = insert_result ? insert_result.rows.size : 0
        planned_count = to_subscribe.size

        imported = really_inserted
        skipped += (planned_count - really_inserted)
      end

      sorted_errors = (pre_errors + limit_errors).sort_by { |item| item[:index] }.map { |item| item[:error] }

      Result.new(imported: imported, skipped: skipped, errors: sorted_errors)
    end
  end
end
