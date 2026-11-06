# frozen_string_literal: true

require "test_helper"

# With solid_queue-coalesce, calls coalesce at enqueue and the rate is checked at
# claim. A job waiting on the rate hasn't started, so it keeps its coalesce key.
class SolidQueue::RateLimitCoalesceTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  class DiscardingJob < ApplicationJob
    coalesce key: ->(account) { account }
    limits_rate to: 1, per: 10.seconds, group: "CoalesceTest", key: :global

    def perform(account)
      JobBuffer.add(account)
    end
  end

  class CollectingJob < ApplicationJob
    coalesce key: ->(account, _id) { account }, on_conflict: :collect, max_calls: 3
    limits_rate to: 1, per: 10.seconds, group: "CoalesceTest", key: :global

    def perform_calls(calls)
      JobBuffer.add(calls.map { |call| call.arguments.last })
    end
  end

  class DispatchingJob < ApplicationJob
    coalesce key: ->(account, _id) { account }, on_conflict: :collect, max_calls: 2, on_full: :dispatch
    limits_rate to: 1, per: 10.seconds, group: "CoalesceTest", key: :global

    def perform_calls(calls); end
  end

  class DebouncedJob < ApplicationJob
    coalesce key: ->(account) { account }, debounce: 5.seconds
    limits_rate to: 1, per: 30.seconds, group: "CoalesceTestSlow", key: :global

    def perform(account)
      JobBuffer.add(account)
    end
  end

  class SlowLimitedJob < ApplicationJob
    limits_rate to: 1, per: 30.seconds, group: "CoalesceTestSlow", key: :global

    def perform; end
  end

  class SyncAccountJob < ApplicationJob
    coalesce key: ->(account) { account }
    limits_concurrency key: ->(account) { account }
    limits_rate to: 1, per: 10.seconds, group: "CoalesceTest", key: :global

    cattr_accessor :during_perform

    def perform(account)
      JobBuffer.add(account)
      during_perform&.call(account)
    end
  end

  setup do
    @start = Time.utc(2026, 1, 1, 12)
    travel_to @start
    @process = SolidQueue::Process.register(kind: "Worker", pid: 42, name: "rate-limit-coalesce-worker")
  end

  teardown do
    SyncAccountJob.during_perform = nil
    travel_back
  end

  test "a job waiting on the rate keeps its coalesce key, so later calls join it and it runs once" do
    first = DiscardingJob.perform_later("a")
    DiscardingJob.perform_later("b")
    perform_claimed

    assert_equal [ "a" ], JobBuffer.values
    assert_equal 1, SolidQueue::ScheduledExecution.count

    later = 3.times.map { DiscardingJob.perform_later("b") }
    assert_equal [ :discarded ] * 3, later.map(&:coalesce_status)
    assert_equal :created, first.coalesce_status

    travel 10.seconds
    SolidQueue::ScheduledExecution.dispatch_next_batch(10)
    perform_claimed

    assert_equal [ "a", "b" ], JobBuffer.values
    assert_equal 2, SolidQueue::Job.count
  end

  test "a collecting job keeps collecting while it waits on the rate, and the next call after it's full opens another" do
    CollectingJob.perform_later("a", 1)
    perform_claimed

    CollectingJob.perform_later("a", 2)
    perform_claimed
    assert_equal [ [ 1 ] ], JobBuffer.values

    statuses = [ 3, 4, 5 ].map { |id| CollectingJob.perform_later("a", id).coalesce_status }
    assert_equal [ :collected, :collected, :created ], statuses

    travel 10.seconds
    SolidQueue::ScheduledExecution.dispatch_next_batch(10)
    perform_claimed
    assert_equal [ [ 1 ], [ 2, 3, 4 ] ], JobBuffer.values

    travel 10.seconds
    SolidQueue::ScheduledExecution.dispatch_next_batch(10)
    perform_claimed
    assert_equal [ [ 1 ], [ 2, 3, 4 ], [ 5 ] ], JobBuffer.values
  end

  test "on_full: :dispatch makes a full job ready, and the claim sends it back to wait on the rate" do
    DispatchingJob.perform_later("a", 1)
    perform_claimed
    job = DispatchingJob.perform_later("a", 2)
    claim

    DispatchingJob.perform_later("a", 3)
    assert SolidQueue::ReadyExecution.exists?(job_id: job.provider_job_id)

    assert_empty claim
    assert SolidQueue::ScheduledExecution.exists?(job_id: job.provider_job_id)
  end

  test "debounce moves a job waiting on the rate only to a later time, so it runs at the later of the two" do
    SlowLimitedJob.perform_later
    claim
    job = DebouncedJob.perform_later("a")

    travel 5.seconds
    SolidQueue::ScheduledExecution.dispatch_next_batch(10)
    assert_empty claim
    assert_equal @start + 30.seconds, scheduled_at(job)

    travel 5.seconds
    DebouncedJob.perform_later("a")
    assert_equal @start + 30.seconds, scheduled_at(job)

    travel 18.seconds
    DebouncedJob.perform_later("a")
    assert_equal @start + 33.seconds, scheduled_at(job)

    travel_to @start + 33.seconds
    SolidQueue::ScheduledExecution.dispatch_next_batch(10)
    perform_claimed
    assert_equal [ "a" ], JobBuffer.values
  end

  test "with all three, an account runs one job at a time, a call during its run waits for it, and other accounts share the rate" do
    SyncAccountJob.perform_later("a")
    SyncAccountJob.perform_later("b")

    SyncAccountJob.during_perform = ->(account) do
      next unless account == "a" && JobBuffer.values == [ "a" ]

      successor = SyncAccountJob.perform_later("a")
      assert_equal :created, successor.coalesce_status
      assert_equal :discarded, SyncAccountJob.perform_later("a").coalesce_status
      assert SolidQueue::BlockedExecution.exists?(job_id: successor.provider_job_id)

      travel 10.seconds
      SolidQueue::ScheduledExecution.dispatch_next_batch(10)
      perform_claimed
      assert_equal [ "a", "b" ], JobBuffer.values

      travel 10.seconds
      assert_empty claim
      assert SolidQueue::BlockedExecution.exists?(job_id: successor.provider_job_id)
    end

    perform_claimed
    assert_equal [ "a", "b" ], JobBuffer.values

    perform_claimed
    assert_equal [ "a", "b", "a" ], JobBuffer.values
    assert_equal 0, SolidQueue::Semaphore.where("value < 1").count
  end

  private
    def claim
      SolidQueue::ReadyExecution.claim("*", 10, @process.id)
    end

    def perform_claimed
      claim.each(&:perform)
    end

    def scheduled_at(active_job)
      SolidQueue::ScheduledExecution.find_by!(job_id: active_job.provider_job_id).scheduled_at
    end
end
