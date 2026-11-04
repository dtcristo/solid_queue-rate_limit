# frozen_string_literal: true

require "test_helper"

class SolidQueue::RateLimitClaimTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  class LimitedJob < ApplicationJob
    limits_rate to: 1, per: 10.seconds, burst: 2

    def perform(value)
      JobBuffer.add(value)
    end
  end

  class UnlimitedJob < ApplicationJob
    def perform(value)
      JobBuffer.add(value)
    end
  end

  setup do
    travel_to Time.utc(2026, 1, 1, 12)
    @process = SolidQueue::Process.register(kind: "Worker", pid: 42, name: "rate-limit-test-worker")
  end

  teardown do
    travel_back
  end

  test "admits up to the burst, then defers the rest as scheduled jobs" do
    jobs = 4.times.map { |i| LimitedJob.perform_later(i) }

    claimed = claim(10)

    assert_equal provider_ids(jobs.first(2)), claimed.map(&:job_id)
    assert_equal provider_ids(jobs.last(2)), SolidQueue::ScheduledExecution.order(:job_id).pluck(:job_id)
    assert_equal 0, SolidQueue::ReadyExecution.count
  end

  test "a deferred job keeps the scheduled_at it was enqueued with" do
    jobs = 3.times.map { |i| LimitedJob.perform_later(i) }
    enqueued_at = SolidQueue::Job.find(jobs.last.provider_job_id).scheduled_at

    claim(10)

    assert_equal enqueued_at, SolidQueue::Job.find(jobs.last.provider_job_id).scheduled_at
    assert_equal Time.current + 10.seconds, SolidQueue::ScheduledExecution.find_by(job_id: jobs.last.provider_job_id).scheduled_at
  end

  test "the dispatcher promotes a deferred job when its slot comes, and the claim admits it" do
    jobs = 3.times.map { |i| LimitedJob.perform_later(i) }
    claim(10).each(&:perform)

    travel 9.seconds
    assert_equal 0, SolidQueue::ScheduledExecution.dispatch_next_batch(10)

    travel 1.second
    assert_equal 1, SolidQueue::ScheduledExecution.dispatch_next_batch(10)
    claim(10).each(&:perform)

    assert_equal [ 0, 1, 2 ], JobBuffer.values
    assert_equal provider_ids(jobs), SolidQueue::Job.finished.order(:id).pluck(:id)
  end

  test "unlimited jobs in the same batch run while limited ones wait" do
    limited = 4.times.map { |i| LimitedJob.perform_later("limited #{i}") }
    unlimited = 2.times.map { |i| UnlimitedJob.perform_later("unlimited #{i}") }

    claimed = claim(10)

    assert_equal provider_ids(limited.first(2) + unlimited), claimed.map(&:job_id).sort
    assert_equal provider_ids(limited.last(2)), SolidQueue::ScheduledExecution.order(:job_id).pluck(:job_id)
  end

  test "admits jobs in queue order" do
    low = LimitedJob.set(priority: 10).perform_later("low")
    high = 2.times.map { |i| LimitedJob.set(priority: 1).perform_later("high #{i}") }

    assert_equal provider_ids(high), claim(10).map(&:job_id)
    assert_equal [ low.provider_job_id ], SolidQueue::ScheduledExecution.pluck(:job_id)
  end

  test "a limit holds across claims" do
    LimitedJob.perform_later(0)
    assert_equal 1, claim(10).size

    LimitedJob.perform_later(1)
    assert_equal 1, claim(10).size

    LimitedJob.perform_later(2)
    assert_equal 0, claim(10).size

    travel 10.seconds
    LimitedJob.perform_later(3)
    assert_equal 1, claim(10).size
  end

  private
    def claim(limit)
      SolidQueue::ReadyExecution.claim("*", limit, @process.id)
    end

    def provider_ids(active_jobs)
      active_jobs.map(&:provider_job_id)
    end
end
