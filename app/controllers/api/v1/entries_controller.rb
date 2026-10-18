# frozen_string_literal: true

require "base64"
require "json"
require "time"

module Api
  module V1
    class EntriesController < BaseController
      DEFAULT_LIMIT = 50
      MAX_LIMIT = 100
      ISO8601_REGEX = /\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:\d{2})\z/

      InvalidParamError = Struct.new(:param)

      def index
        parsed = parse_query_params
        if parsed.is_a?(InvalidParamError)
          return render_error(
            code: :bad_request,
            message: "Invalid #{parsed.param} parameter",
            status: :bad_request,
            details: { param: parsed.param.to_s }
          )
        end

        subscription, subscription_ids_by_feed_id = resolve_subscriptions!

        rows = fetch_entries(
          subscription: subscription,
          unread: parsed[:unread],
          starred: parsed[:starred],
          cursor: parsed[:cursor],
          limit: parsed[:limit]
        )

        has_more = rows.length > parsed[:limit]
        page_entries = rows.first(parsed[:limit])
        next_cursor = has_more ? encode_cursor(page_entries.last) : nil

        render json: {
          entries: page_entries.map do |entry|
            EntrySummaryPresenter.new(
              entry,
              subscription_id: subscription_ids_by_feed_id[entry.feed_id]
            ).as_json
          end,
          next_cursor: next_cursor
        }
      end

      private

      def parse_query_params
        limit = parse_limit
        return limit if limit.is_a?(InvalidParamError)

        unread = parse_boolean(:unread)
        return unread if unread.is_a?(InvalidParamError)

        starred = parse_boolean(:starred)
        return starred if starred.is_a?(InvalidParamError)

        cursor = parse_cursor
        return cursor if cursor.is_a?(InvalidParamError)

        {
          limit: limit,
          unread: unread,
          starred: starred,
          cursor: cursor
        }
      end

      def parse_limit
        return DEFAULT_LIMIT unless params.key?(:limit)

        raw = params[:limit].to_s
        return InvalidParamError.new(:limit) unless raw.match?(/\A-?\d+\z/)

        value = raw.to_i
        return InvalidParamError.new(:limit) if value < 1

        [ value, MAX_LIMIT ].min
      end

      def parse_boolean(param_name)
        return nil unless params.key?(param_name)

        case params[param_name]
        when "true" then true
        when "false" then false
        else InvalidParamError.new(param_name)
        end
      end

      def parse_cursor
        return nil unless params.key?(:cursor)

        raw = params[:cursor]
        return InvalidParamError.new(:cursor) unless raw.is_a?(String) && raw.match?(/\A[A-Za-z0-9_-]+\z/)

        decoded = Base64.urlsafe_decode64(raw)
        return InvalidParamError.new(:cursor) unless Base64.urlsafe_encode64(decoded, padding: false) == raw

        payload = JSON.parse(decoded)
        return InvalidParamError.new(:cursor) unless payload.is_a?(Hash) && payload.keys.sort == %w[id published_at]

        id = payload["id"]
        published_at_str = payload["published_at"]
        return InvalidParamError.new(:cursor) unless id.is_a?(Integer) && id.positive?
        return InvalidParamError.new(:cursor) unless published_at_str.is_a?(String) && published_at_str.match?(ISO8601_REGEX)

        published_at = Time.iso8601(published_at_str).utc
        { published_at: published_at, id: id }
      rescue ArgumentError, JSON::ParserError, EncodingError
        InvalidParamError.new(:cursor)
      end

      def encode_cursor(entry)
        payload = {
          published_at: entry.published_at.utc.iso8601(6),
          id: entry.id
        }
        Base64.urlsafe_encode64(JSON.generate(payload), padding: false)
      end

      def resolve_subscriptions!
        subscriptions_scope = current_user.subscriptions
        if params.key?(:subscription_id)
          raw_sub_id = params[:subscription_id]
          raise ActiveRecord::RecordNotFound unless raw_sub_id.is_a?(String) && raw_sub_id.match?(/\A\d+\z/)

          subscription = subscriptions_scope.find(raw_sub_id)
          [ subscription, { subscription.feed_id => subscription.id.to_s } ]
        else
          map = subscriptions_scope.pluck(:feed_id, :id).to_h.transform_values(&:to_s)
          [ nil, map ]
        end
      end

      def fetch_entries(subscription:, unread:, starred:, cursor:, limit:)
        state_join_sql = Entry.sanitize_sql_array([
          "LEFT JOIN entry_states ON entry_states.entry_id = entries.id AND entry_states.user_id = ?",
          current_user.id
        ])

        scope = Entry
          .joins("INNER JOIN subscriptions ON subscriptions.feed_id = entries.feed_id")
          .where(subscriptions: { user_id: current_user.id })
          .joins(state_join_sql)
          .select(
            "entries.id",
            "entries.feed_id",
            "entries.title",
            "entries.author",
            "entries.url",
            "entries.published_at",
            "entry_states.read_at AS state_read_at",
            "entry_states.starred_at AS state_starred_at"
          )

        scope = scope.where(subscriptions: { id: subscription.id }) if subscription

        if unread == true
          scope = scope.where(entry_states: { read_at: nil })
        elsif unread == false
          scope = scope.where.not(entry_states: { read_at: nil })
        end

        if starred == true
          scope = scope.where.not(entry_states: { starred_at: nil })
        elsif starred == false
          scope = scope.where(entry_states: { starred_at: nil })
        end

        if cursor
          scope = scope.where(
            "entries.published_at < ? OR (entries.published_at = ? AND entries.id < ?)",
            cursor[:published_at],
            cursor[:published_at],
            cursor[:id]
          )
        end

        scope.order(published_at: :desc, id: :desc).limit(limit + 1).to_a
      end
    end
  end
end
