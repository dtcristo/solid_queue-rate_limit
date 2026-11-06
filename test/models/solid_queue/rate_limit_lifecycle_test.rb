# frozen_string_literal: true

require "test_helper"

# Every time a job reaches ready it's charged again, however it got there
class SolidQueue::RateLimitLifecycleTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  class LimitedJob < ApplicationJob
    limits_rate to: 1, per: 10.seconds, key: :global

    def perform(value)
      JobBuffer.add(value)
    end
  end

  class RetryingJob < ApplicationJob
    limits_rate to: 1, per: 10.seconds, key: :global
    retry_on ExpectedTestError, wait: 0, attempts: 2

    def perform
      JobBuffer.add(executions)
      raise ExpectedTestError if executions == 1
    end
  end

  class FailingJob < ApplicationJob
    limits_rate to: 1, per: 10.seconds, key: :global

    def perform
      raise ExpectedTestError
    end
  end

  setup do
    @start = Time.utc(2026, 1, 1, 12)
    travel_to @start
    @process = SolidQueue::Process.register(kind: "Worker", pid: 42, name: "rate-limit-lifecycle-worker")
  end

  teardown do
    travel_back
  end

  test "a retry from retry_on is charged again" do
    RetryingJob.perform_later
    perform_claimed

    assert_empty claim
    assert_equal 1, SolidQueue::ScheduledExecution.count
    assert_equal [ 1 ], JobBuffer.values

    travel 10.seconds
    SolidQueue::ScheduledExecution.dispatch_next_batch(10)
    perform_claimed

    assert_equal [ 1, 2 ], JobBuffer.values
  end

  test "retrying a failed job is charged again" do
    FailingJob.perform_later
    assert_raises(ExpectedTestError) { perform_claimed }

    SolidQueue::FailedExecution.sole.retry

    assert_empty claim
    assert_equal @start + 10.seconds, SolidQueue::ScheduledExecution.sole.scheduled_at
  end

  test "a released claim is charged again" do
    LimitedJob.perform_later("released")
    claim.sole.release

    assert_empty claim
    assert_equal 1, SolidQueue::ScheduledExecution.count
  end

  test "a job enqueued with wait is dispatched at its time, then admitted" do
    active_job = LimitedJob.set(wait: 5.seconds).perform_later("waited")
    SolidQueue::ScheduledExecution.dispatch_next_batch(10)
    assert_empty claim

    travel 5.seconds
    SolidQueue::ScheduledExecution.dispatch_next_batch(10)

    assert_equal [ active_job.provider_job_id ], claim.map(&:job_id)
  end

  test "a job enqueued with wait into a spent budget waits again, keeping its own time" do
    LimitedJob.perform_later("first")
    claim
    active_job = LimitedJob.set(wait: 5.seconds).perform_later("waited")

    travel 5.seconds
    SolidQueue::ScheduledExecution.dispatch_next_batch(10)

    assert_empty claim
    assert_equal @start + 10.seconds, SolidQueue::ScheduledExecution.sole.scheduled_at
    assert_equal @start + 5.seconds, SolidQueue::Job.find(active_job.provider_job_id).scheduled_at
  end

  test "recurring tasks are limited like any other enqueue" do
    task = SolidQueue::RecurringTask.create!(key: "limited", class_name: LimitedJob.name, arguments: [ "tick" ], schedule: "every second")

    task.enqueue(at: Time.current)
    task.enqueue(at: Time.current + 1.second)

    assert_equal 1, claim.size
    assert_equal 1, SolidQueue::ScheduledExecution.count
  end

  test "a deferred job can be discarded, and its slot is left unused" do
    jobs = 3.times.map { |i| LimitedJob.perform_later(i) }
    claim

    SolidQueue::Job.find(jobs.second.provider_job_id).discard
    assert_equal [ jobs.third.provider_job_id ], SolidQueue::ScheduledExecution.pluck(:job_id)

    travel 10.seconds
    SolidQueue::ScheduledExecution.dispatch_next_batch(10)
    assert_empty claim

    travel 10.seconds
    SolidQueue::ScheduledExecution.dispatch_next_batch(10)
    assert_equal [ jobs.third.provider_job_id ], claim.map(&:job_id)
  end

  private
    def claim
      SolidQueue::ReadyExecution.claim("*", 10, @process.id)
    end

    def perform_claimed
      claim.each(&:perform)
    end
end
