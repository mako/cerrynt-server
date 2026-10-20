# frozen_string_literal: true

module Entries
  class MarkRead
    def self.call(user:, subscription_id: nil, before: nil)
      new(user: user, subscription_id: subscription_id, before: before).call
    end

    def initialize(user:, subscription_id: nil, before: nil)
      @user_id = user.is_a?(User) ? user.id : user
      @subscription_id = subscription_id
      @before = before
    end

    def call
      EntryState.transaction(requires_new: true) do
        now = Time.current
        candidates = build_candidates_scope
        update_existing_states(candidates, now) + insert_missing_states(candidates, now)
      end
    end

    private

    def build_candidates_scope
      scope = Entry.visible_to(@user_id)
                   .reselect("entries.id")
                   .where(entry_states: { read_at: nil })
      scope = scope.where("entries.published_at <= ?", @before) if @before
      scope = scope.where(subscriptions: { id: @subscription_id }) if @subscription_id
      scope
    end

    def update_existing_states(candidates, now)
      EntryState
        .where(user_id: @user_id, read_at: nil, entry_id: candidates)
        .update_all(read_at: now, updated_at: now)
    end

    def insert_missing_states(candidates, now)
      select_sql = candidates
        .reselect(
          Entry.sanitize_sql_array([
            "? AS user_id, entries.id AS entry_id, ? AS read_at, ? AS created_at, ? AS updated_at",
            @user_id, now, now, now
          ])
        )
        .where(
          Entry.sanitize_sql_array([
            "NOT EXISTS (SELECT 1 FROM entry_states es WHERE es.entry_id = entries.id AND es.user_id = ?)",
            @user_id
          ])
        )
        .to_sql

      sql = "INSERT INTO entry_states (user_id, entry_id, read_at, created_at, updated_at) " \
            "#{select_sql} ON CONFLICT DO NOTHING"

      EntryState.connection.update(sql, "EntryState Bulk Insert")
    end
  end
end
