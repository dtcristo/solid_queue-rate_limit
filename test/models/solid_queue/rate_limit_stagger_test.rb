# frozen_string_literal: true

require "test_helper"

# Waiting jobs get staggered next checks, so a backlog doesn't bounce between
# scheduled and ready on every dispatcher poll.
class SolidQueue::RateLimitStaggerTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  class EverySecondJob < ApplicationJob
    limits_rate to: 1, per: 1.second

    def perform; end
  end

  # Enough burst for a dispatcher that polls every second: to × polling_interval / per = 2
  class TwiceASecondJob < ApplicationJob
    limits_rate to: 2, per: 1.second, burst: 4

    def perform; end
  end

  class EveryMinuteJob < ApplicationJob
    limits_rate to: 1, per: 1.minute

    def perform; end
  end

  setup do
    @start = Time.utc(2026, 1, 1, 12)
    travel_to @start
    @process = SolidQueue::Process.register(kind: "Worker", pid: 42, name: "rate-limit-stagger-worker")
    @deferrals = 0
    @subscriber = ActiveSupport::Notifications.subscribe("defer_rate_limited.solid_queue") { |event| @deferrals += event.payload[:size] }
  end

  teardown do
    ActiveSupport::Notifications.unsubscribe(@subscriber)
    travel_back
  end

  test "waiting jobs get slots one interval apart" do
    4.times { EverySecondJob.perform_later }

    claim

    assert_equal [ 1, 2, 3 ].map { |seconds| @start + seconds }, SolidQueue::ScheduledExecution.order(:scheduled_at).pluck(:scheduled_at)
  end

  test "later claims hand out the slots after the ones already taken" do
    2.times { EverySecondJob.perform_later }
    claim
    2.times { EverySecondJob.perform_later }
    claim

    assert_equal [ 1, 2, 3 ].map { |seconds| @start + seconds }, SolidQueue::ScheduledExecution.order(:scheduled_at).pluck(:scheduled_at)
  end

  test "a backlog drains at the rate with about one deferral per job" do
    admitted = []
    30.times { TwiceASecondJob.perform_later }

    run_worker_and_dispatcher(20.seconds) { |claimed| admitted.concat(claimed.map { Time.current - @start }) }

    assert_equal 30, admitted.size
    assert_operator admitted.max, :<=, 15
    assert_operator admitted.map { |t0| admitted.count { |t| t >= t0 && t < t0 + 1 } }.max, :<=, 4 + 2
    assert_operator @deferrals, :<=, 30
  end

  test "slots stop 5 minutes ahead, and later jobs check again in 5 minutes without taking one" do
    8.times { EveryMinuteJob.perform_later }

    claim

    expected = (1..5).map { |minutes| @start + minutes.minutes } + [ @start + 5.minutes ] * 2
    assert_equal expected, SolidQueue::ScheduledExecution.order(:scheduled_at, :job_id).pluck(:scheduled_at)
  end

  test "after waiting jobs are discarded, a new job still runs within 5 minutes" do
    7.times { EveryMinuteJob.perform_later }
    claim
    SolidQueue::ScheduledExecution.discard_all_in_batches

    travel 1.second
    active_job = EveryMinuteJob.perform_later
    claimed = []
    run_worker_and_dispatcher(5.minutes, step: 1.second) { |executions| claimed.concat(executions.map(&:job_id)) }

    assert_equal [ active_job.provider_job_id ], claimed
  end

  test "a job enqueued once the budget recovers runs at once, whatever slots were handed out" do
    7.times { EveryMinuteJob.perform_later }
    claim
    SolidQueue::ScheduledExecution.discard_all_in_batches

    travel 1.minute
    active_job = EveryMinuteJob.perform_later

    assert_equal [ active_job.provider_job_id ], claim.map(&:job_id)
  end

  private
    def claim
      SolidQueue::ReadyExecution.claim("*", 10, @process.id)
    end

    # A worker polling every step and a dispatcher every second, in simulated time
    def run_worker_and_dispatcher(duration, step: 0.1.seconds, &block)
      finish_at = Time.current + duration
      dispatched_at = nil

      while Time.current <= finish_at
        if dispatched_at.nil? || Time.current - dispatched_at >= 1
          SolidQueue::ScheduledExecution.dispatch_next_batch(500)
          dispatched_at = Time.current
        end

        claimed = claim
        SolidQueue::Job.where(id: claimed.map(&:job_id)).destroy_all
        block.call(claimed)

        travel step, with_usec: true
      end
    end
end
