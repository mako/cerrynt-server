# frozen_string_literal: true

module Entries
  class UpdateState
    def self.call(user:, entry_id:, read: nil, starred: nil)
      new(user: user, entry_id: entry_id, read: read, starred: starred).call
    end

    def initialize(user:, entry_id:, read: nil, starred: nil)
      @user_id = user.is_a?(User) ? user.id : user
      @entry_id = entry_id
      @read = read
      @starred = starred
    end

    def call
      attempts = 0
      begin
        attempts += 1
        EntryState.write_transaction do |now|
          state = find_existing_state

          if state.nil?
            create_state_if_needed!(now)
          else
            update_state_if_needed!(state, now)
          end
        end
      rescue ActiveRecord::RecordNotUnique
        retry if attempts < 2
        raise
      end
    end

    private

    def find_existing_state
      EntryState.lock.find_by(user_id: @user_id, entry_id: @entry_id)
    end

    def create_state_if_needed!(now)
      new_read_at = (@read == true) ? now : nil
      new_starred_at = (@starred == true) ? now : nil
      return nil if new_read_at.nil? && new_starred_at.nil?

      state = EntryState.new(
        user_id: @user_id,
        entry_id: @entry_id,
        read_at: new_read_at,
        starred_at: new_starred_at,
        created_at: now,
        updated_at: now
      )
      state.save!(validate: false)
      state
    end

    def update_state_if_needed!(state, now)
      new_read_at = resolve_timestamp(@read, state.read_at, now)
      new_starred_at = resolve_timestamp(@starred, state.starred_at, now)

      read_changed = state.read_at != new_read_at
      starred_changed = state.starred_at != new_starred_at
      return state unless read_changed || starred_changed

      state.update_columns(
        read_at: new_read_at,
        starred_at: new_starred_at,
        updated_at: now
      )
      state
    end

    def resolve_timestamp(flag, current_timestamp, now)
      if flag == true
        current_timestamp || now
      elsif flag == false
        nil
      else
        current_timestamp
      end
    end
  end
end
