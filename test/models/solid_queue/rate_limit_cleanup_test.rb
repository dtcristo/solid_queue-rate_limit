# frozen_string_literal: true

require "test_helper"

class SolidQueue::RateLimitCleanupTest < ActiveSupport::TestCase
  class AccountJob < ApplicationJob
    limits_rate to: 1, per: 1.minute, key: ->(account) { account }

    def perform(account); end
  end

  setup do
    travel_to Time.utc(2026, 1, 1, 12)
    @process = SolidQueue::Process.register(kind: "Worker", pid: 42, name: "rate-limit-cleanup-worker")
  end

  teardown do
    travel_back
  end

  test "clears the budgets that are full and have no slots ahead, in batches" do
    SolidQueue::RateLimitState.create!(key: "full", tat: 1.second.ago)
    SolidQueue::RateLimitState.create!(key: "full with slots passed", tat: 1.second.ago, deferred_until: 1.second.ago)
    SolidQueue::RateLimitState.create!(key: "spent", tat: 1.second.from_now)
    SolidQueue::RateLimitState.create!(key: "spent with slots passed", tat: 1.second.from_now, deferred_until: 1.second.ago)
    SolidQueue::RateLimitState.create!(key: "slots ahead", tat: 1.second.ago, deferred_until: 1.second.from_now)

    SolidQueue::RateLimitState.clear_idle_in_batches(batch_size: 1)

    assert_equal [ "slots ahead", "spent", "spent with slots passed" ], SolidQueue::RateLimitState.order(:key).pluck(:key)
  end

  test "a cleared budget admits and staggers as one that was never used" do
    3.times { AccountJob.perform_later("a") }
    claim(10)
    SolidQueue::Job.destroy_all
    travel 2.minutes + 1.second

    assert_difference -> { SolidQueue::RateLimitState.count }, -1 do
      SolidQueue::RateLimitState.clear_idle_in_batches
    end

    jobs = %w[ a b ].index_with { |account| Array.new(3) { AccountJob.perform_later(account) } }
    claimed = claim(10).map(&:job_id)

    jobs.each do |account, (first, *rest)|
      assert_includes claimed, first.provider_job_id, account
      assert_equal [ 1.minute.from_now, 2.minutes.from_now ], next_checks(rest), account
    end
  end

  test "a budget charged while the cleanup runs isn't cleared" do
    SolidQueue::RateLimitState.create!(key: "#{AccountJob.name}/a", tat: 1.second.ago)
    AccountJob.perform_later("a")

    after_first_state_query(-> { claim(10) }) { SolidQueue::RateLimitState.clear_idle_in_batches }
    job = AccountJob.perform_later("a")

    assert_empty claim(10)
    assert_equal [ 1.minute.from_now ], next_checks([ job ])
  end

  test "a claim succeeds when the cleanup clears its budget while it runs" do
    SolidQueue::RateLimitState.create!(key: "#{AccountJob.name}/a", tat: 1.second.ago)
    jobs = Array.new(2) { AccountJob.perform_later("a") }

    claimed = after_first_state_query(-> { SolidQueue::RateLimitState.clear_idle_in_batches }) { claim(10) }

    assert_equal [ jobs.first.provider_job_id ], claimed.map(&:job_id)
    assert_equal [ 1.minute.from_now ], next_checks(jobs.last(1))
  end

  private
    # Runs interruption once, right after the block's first query on the state table,
    # so it lands between that query and the block's next one
    def after_first_state_query(interruption, &block)
      interrupted = false
      subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
        if !interrupted && payload[:name] != "SCHEMA" && payload[:sql].include?(SolidQueue::RateLimitState.table_name)
          interrupted = true
          interruption.call
        end
      end
      block.call.tap { assert interrupted, "the block queried the state table" }
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end

    def next_checks(active_jobs)
      SolidQueue::ScheduledExecution.where(job_id: active_jobs.map(&:provider_job_id)).order(:scheduled_at).pluck(:scheduled_at)
    end

    def claim(limit)
      SolidQueue::ReadyExecution.claim("*", limit, @process.id)
    end
end
