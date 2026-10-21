# frozen_string_literal: true

module Entries
  class Changes
    PAGE_SIZE = 100

    CHANGED_AT_SQL = <<~SQL.squish.freeze
      CASE
        WHEN entry_states.updated_at IS NOT NULL
         AND entry_states.updated_at >= entries.updated_at
         AND entry_states.updated_at >= subscriptions.created_at
        THEN entry_states.updated_at
        WHEN entries.updated_at >= subscriptions.created_at
        THEN entries.updated_at
        ELSE subscriptions.created_at
      END
    SQL

    DB_TIMESTAMP_REGEX = /\A(\d{4})-(\d{2})-(\d{2})[ T](\d{2}):(\d{2}):(\d{2})(?:\.(\d{1,6}))?/

    def self.call(user:, since: nil)
      new(user: user, since: since).call
    end

    def initialize(user:, since: nil)
      @user = user
      @since = validate_since!(since)
    end

    def call
      rows = fetch_entries
      has_more = rows.length > PAGE_SIZE
      page_rows = rows.first(PAGE_SIZE)

      cursor = compute_cursor(page_rows)
      entries = page_rows.map { |entry| EntrySummaryPresenter.new(entry).as_json }
      subscriptions = fetch_subscriptions

      {
        subscriptions: subscriptions,
        entries: entries,
        cursor: cursor,
        has_more: has_more
      }
    end

    private

    def validate_since!(since)
      return nil if since.nil?

      unless since.is_a?(Array) && since.length == 2 &&
             since[0].is_a?(Time) && since[1].is_a?(Integer) && since[1] >= 0
        raise ArgumentError, "since must be a decoded [Time, Integer] pair or nil"
      end

      [ since[0].utc, since[1] ]
    end

    def fetch_entries
      scope = Entry.visible_to(@user)
                   .reselect(*Entry::SUMMARY_COLUMNS, "#{CHANGED_AT_SQL} AS changed_at")

      if @since
        since_time, since_id = @since
        scope = scope.where(
          "(#{CHANGED_AT_SQL}) > ? OR ((#{CHANGED_AT_SQL}) = ? AND entries.id > ?)",
          since_time,
          since_time,
          since_id
        )
      end

      scope
        .order(Arel.sql("(#{CHANGED_AT_SQL}) ASC, entries.id ASC"))
        .limit(PAGE_SIZE + 1)
        .to_a
    end

    def fetch_subscriptions
      subs = @user.subscriptions.includes(:feed).order(:created_at, :id).to_a
      feed_ids = subs.map(&:feed_id)
      unread_counts = Entry.unread_counts_for(@user, feed_ids)

      subs.map do |subscription|
        SubscriptionPresenter.new(
          subscription,
          unread_count: unread_counts[subscription.feed_id] || 0
        ).as_json
      end
    end

    def compute_cursor(page_rows)
      if page_rows.any?
        last_row = page_rows.last
        Entries::SyncCursor.encode(
          changed_at: parse_changed_at(last_row[:changed_at]),
          id: last_row.id
        )
      elsif @since
        Entries::SyncCursor.encode(changed_at: @since[0], id: @since[1])
      else
        Entries::SyncCursor::EPOCH
      end
    end

    def parse_changed_at(raw)
      return raw.utc if raw.is_a?(Time)

      match = DB_TIMESTAMP_REGEX.match(raw.to_s)
      raise ArgumentError, "Unexpected changed_at value: #{raw.inspect}" unless match

      frac = match[7] ? match[7].ljust(6, "0").to_i : 0
      Time.utc(
        match[1].to_i,
        match[2].to_i,
        match[3].to_i,
        match[4].to_i,
        match[5].to_i,
        match[6].to_i,
        frac
      )
    end
  end
end
