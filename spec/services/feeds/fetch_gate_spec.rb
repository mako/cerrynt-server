# frozen_string_literal: true

require "rails_helper"

RSpec.describe Feeds::FetchGate do
  describe "capacity calculation" do
    it "derives capacity from RAILS_MAX_THREADS (3 -> 2, 2 -> 1, 1 -> 1, unset -> 2)" do
      with_env("MAX_INTERACTIVE_FETCHES" => nil, "RAILS_MAX_THREADS" => "3") do
        expect(described_class.capacity).to eq(2)
      end

      with_env("MAX_INTERACTIVE_FETCHES" => nil, "RAILS_MAX_THREADS" => "2") do
        expect(described_class.capacity).to eq(1)
      end

      with_env("MAX_INTERACTIVE_FETCHES" => nil, "RAILS_MAX_THREADS" => "1") do
        expect(described_class.capacity).to eq(1)
      end

      with_env("MAX_INTERACTIVE_FETCHES" => nil, "RAILS_MAX_THREADS" => nil) do
        expect(described_class.capacity).to eq(2)
      end
    end

    it "allows MAX_INTERACTIVE_FETCHES to override capacity within clamped bounds" do
      with_env("RAILS_MAX_THREADS" => "3", "MAX_INTERACTIVE_FETCHES" => "1") do
        expect(described_class.capacity).to eq(1)
      end

      with_env("RAILS_MAX_THREADS" => "3", "MAX_INTERACTIVE_FETCHES" => "2") do
        expect(described_class.capacity).to eq(2)
      end

      with_env("RAILS_MAX_THREADS" => "3", "MAX_INTERACTIVE_FETCHES" => "10") do
        expect(described_class.capacity).to eq(2)
      end

      with_env("RAILS_MAX_THREADS" => "3", "MAX_INTERACTIVE_FETCHES" => "0") do
        expect(described_class.capacity).to eq(1)
      end

      with_env("RAILS_MAX_THREADS" => "1", "MAX_INTERACTIVE_FETCHES" => "5") do
        expect(described_class.capacity).to eq(1)
      end
    end
  end

  describe ".try_run" do
    it "returns the value of the block on success" do
      result = described_class.try_run { "fetch_result_payload" }
      expect(result).to eq("fetch_result_payload")
    end

    it "returns :busy and does not run the block when all slots are taken" do
      with_env("RAILS_MAX_THREADS" => "2") do # capacity = 1
        block_ran = false
        described_class.try_run do
          inner_result = Timeout.timeout(5) do
            described_class.try_run do
              block_ran = true
              "inner_value"
            end
          end

          expect(inner_result).to eq(:busy)
        end

        expect(block_ran).to be false
      end
    end

    it "always releases the slot in an ensure block when the block raises" do
      expect {
        described_class.try_run { raise StandardError, "simulated network explosion" }
      }.to raise_error(StandardError, "simulated network explosion")

      subsequent_result = described_class.try_run { :recovered }
      expect(subsequent_result).to eq(:recovered)
    end

    it "does not leak permits after many sequential calls" do
      with_env("RAILS_MAX_THREADS" => "2") do # capacity = 1
        100.times do |i|
          result = described_class.try_run { i }
          expect(result).to eq(i)
        end

        final_result = described_class.try_run { :still_free }
        expect(final_result).to eq(:still_free)
      end
    end

    it "proves with real threads that at most capacity blocks run concurrently and extra callers get :busy" do
      with_env("RAILS_MAX_THREADS" => "3") do # capacity = 2
        expect(described_class.capacity).to eq(2)

        started_queue = Queue.new
        release_queue = Queue.new

        t1 = Thread.new do
          described_class.try_run do
            started_queue << :t1
            release_queue.pop
            :t1_done
          end
        end

        t2 = Thread.new do
          described_class.try_run do
            started_queue << :t2
            release_queue.pop
            :t2_done
          end
        end

        begin
          # Wait deterministically until both slots are actively held
          Timeout.timeout(5) do
            2.times { started_queue.pop }
          end

          # 3rd caller tries to acquire when all 2 slots are occupied; must fail fast if blocking
          extra_block_ran = false
          extra_result = Timeout.timeout(5) do
            described_class.try_run do
              extra_block_ran = true
              :extra
            end
          end

          expect(extra_result).to eq(:busy)
          expect(extra_block_ran).to be false
        ensure
          2.times { release_queue << :proceed }
          t1.kill
          t2.kill
          t1.join(1)
          t2.join(1)
        end

        # Gate has freed slots again
        after_result = described_class.try_run { :available_again }
        expect(after_result).to eq(:available_again)
      end
    end
  end
end
