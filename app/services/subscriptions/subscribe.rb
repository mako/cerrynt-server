# frozen_string_literal: true

module Subscriptions
  class Subscribe
    Result = Data.define(:outcome, :error, :message, :details, :subscription) do
      def created?
        outcome == :created
      end

      def existing?
        outcome == :existing
      end

      def failed?
        outcome == :failed
      end
    end

    def self.call(user:, url:, fetcher: Feeds::Fetcher.method(:call))
      new(user: user, url: url, fetcher: fetcher).call
    end

    def initialize(user:, url:, fetcher: Feeds::Fetcher.method(:call))
      @user = user
      @url = url
      @fetcher = fetcher
    end

    def call
      # 1. Validate the param: blank, missing, non-String, or longer than MAX_URL_LENGTH
      unless @url.is_a?(String) && @url.strip.present? && @url.length <= Feeds::Fetcher::MAX_URL_LENGTH
        return failure(
          error: :invalid_feed_url,
          message: "Invalid feed URL"
        )
      end

      normalized_url = Feed.normalize_value_for(:url, @url)

      # 2. If a Feed with that normalized url exists
      existing_feed = Feed.find_by(url: normalized_url)
      if existing_feed
        existing_sub = @user.subscriptions.find_by(feed: existing_feed)
        return existing_result(existing_sub) if existing_sub

        return limit_reached_failure if feed_limit_reached?

        return subscribe_to_existing_feed(existing_feed)
      end

      # 3. If the feed does not exist: check plan limit first (cheap rejection with NO fetch)
      return limit_reached_failure if feed_limit_reached?

      # Fetch with injected fetcher OUTSIDE any transaction
      fetch_result = @fetcher.call(normalized_url)

      # 4. On a fetch failure: respond immediately and write nothing
      unless fetch_result.ok?
        return handle_fetch_failure(fetch_result)
      end

      # 5. On success: lock user row and persist
      subscribe_and_refresh(normalized_url, fetch_result)
    end

    private

    def feed_limit_reached?
      @user.subscriptions.count >= Plan.max_feeds_for(@user.plan)
    end

    def limit_reached_failure
      limit = Plan.max_feeds_for(@user.plan)
      Result.new(
        outcome: :failed,
        error: :feed_limit_reached,
        message: "#{@user.plan.capitalize} plan allows #{limit} #{'feed'.pluralize(limit)}.",
        details: { limit: limit, plan: @user.plan },
        subscription: nil
      )
    end

    def existing_result(subscription)
      Result.new(
        outcome: :existing,
        error: nil,
        message: nil,
        details: {},
        subscription: subscription
      )
    end

    def failure(error:, message:, details: {})
      Result.new(
        outcome: :failed,
        error: error,
        message: message,
        details: details,
        subscription: nil
      )
    end

    def handle_fetch_failure(fetch_result)
      case fetch_result.error
      when :not_a_feed
        failure(error: :invalid_feed_url, message: "URL does not point to a valid feed")
      when :invalid_url
        failure(error: :invalid_feed_url, message: "Invalid feed URL")
      else
        failure(error: :feed_unreachable, message: "Feed is unreachable")
      end
    end

    def find_or_create_feed(normalized_url)
      Feed.find_by(url: normalized_url) || begin
        Feed.transaction(requires_new: true) do
          Feed.create!(url: normalized_url)
        end
      rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid => e
        raise unless e.is_a?(ActiveRecord::RecordNotUnique) || e.record.errors.of_kind?(:url, :taken)

        Feed.find_by!(url: normalized_url)
      end
    end

    def find_or_create_subscription(feed)
      existing = @user.subscriptions.find_by(feed: feed)
      return [ existing, false ] if existing

      created_sub = begin
        Subscription.transaction(requires_new: true) do
          @user.subscriptions.create!(feed: feed)
        end
      rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid => e
        raise unless e.is_a?(ActiveRecord::RecordNotUnique) || e.record.errors.of_kind?(:feed_id, :taken)

        nil
      end

      if created_sub
        [ created_sub, true ]
      else
        [ @user.subscriptions.find_by!(feed: feed), false ]
      end
    end

    def subscribe_to_existing_feed(existing_feed)
      result = nil
      @user.with_lock do
        existing_sub = @user.subscriptions.find_by(feed: existing_feed)
        if existing_sub
          result = existing_result(existing_sub)
        elsif feed_limit_reached?
          result = limit_reached_failure
        else
          subscription, created = find_or_create_subscription(existing_feed)
          result = Result.new(
            outcome: created ? :created : :existing,
            error: nil,
            message: nil,
            details: {},
            subscription: subscription
          )
        end
      end
      result
    end

    def subscribe_and_refresh(normalized_url, fetch_result)
      result = nil
      @user.with_lock do
        existing_feed = Feed.find_by(url: normalized_url)
        existing_sub = existing_feed && @user.subscriptions.find_by(feed: existing_feed)

        if existing_sub
          result = existing_result(existing_sub)
        elsif feed_limit_reached?
          result = limit_reached_failure
        else
          feed = existing_feed || find_or_create_feed(normalized_url)
          subscription, created = find_or_create_subscription(feed)

          refresh_result = Feeds::Refresh.call(feed, fetcher: ->(_url) { fetch_result })
          raise "Feeds::Refresh failed unexpectedly: #{refresh_result.error}" unless refresh_result.ok?

          feed.reload

          result = Result.new(
            outcome: created ? :created : :existing,
            error: nil,
            message: nil,
            details: {},
            subscription: subscription
          )
        end
      end
      result
    end
  end
end
