# frozen_string_literal: true

require "concurrent"

module Feeds
  # Process-wide, thread-safe concurrency gate for interactive feed fetches.
  #
  # Uses a Concurrent::Semaphore to bound concurrent synchronous fetches so that
  # at least one Puma thread always remains free for authentication and health checks.
  #
  # IMPORTANT: This gate is strictly for interactive web requests (e.g. Subscribe).
  # Background jobs (Phase R3.5) MUST NOT use this gate.
  class FetchGate
    RETRY_AFTER = 5

    @mutex = Mutex.new
    @semaphore = nil
    @pid = nil
    @capacity = nil

    class << self
      def try_run
        sem = semaphore
        return :busy unless sem.try_acquire

        begin
          yield
        ensure
          sem.release
        end
      end

      def capacity
        ensure_initialized
        @capacity
      end

      def reset!
        @mutex.synchronize do
          @semaphore = nil
          @pid = nil
          @capacity = nil
        end
      end

      private

      def semaphore
        ensure_initialized
        @semaphore
      end

      def ensure_initialized
        current_pid = Process.pid
        return if @semaphore && @pid == current_pid

        @mutex.synchronize do
          return if @semaphore && @pid == current_pid

          # Capacity uses ENV.fetch("RAILS_MAX_THREADS", 3).to_i - 1
          # (matching the same variable and default as config/puma.rb), at least 1.
          # MAX_INTERACTIVE_FETCHES may override it, clamped to 1..(threads - 1) (1 when threads is 1).
          @capacity = compute_capacity
          @semaphore = Concurrent::Semaphore.new(@capacity)
          @pid = current_pid
        end
      end

      def compute_capacity
        # Matches config/puma.rb default of 3 threads
        threads = [ ENV.fetch("RAILS_MAX_THREADS", 3).to_i, 1 ].max
        max_allowed = [ threads - 1, 1 ].max

        if ENV["MAX_INTERACTIVE_FETCHES"].present?
          override = ENV["MAX_INTERACTIVE_FETCHES"].to_i
          override.clamp(1, max_allowed)
        else
          max_allowed
        end
      end
    end
  end
end
