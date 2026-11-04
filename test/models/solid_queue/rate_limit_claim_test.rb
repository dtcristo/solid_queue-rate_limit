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

  def self.const_missing(name)
    name == :BrokenJob ? raise(SyntaxError, "broken") : super
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

  test "a job that still has a concurrency key is admitted without a rate check" do
    jobs = 3.times.map { |i| LimitedJob.perform_later(i) }
    SolidQueue::Job.update_all(concurrency_key: "switched from limits_concurrency")

    assert_equal provider_ids(jobs), claim(10).map(&:job_id)
    assert_equal 0, SolidQueue::ScheduledExecution.count
  end

  test "a class that dropped its limit has its jobs claimed, deferred ones included" do
    3.times { |i| LimitedJob.perform_later(i) }
    claim(10)

    LimitedJob.with(rate_limit_to: nil) do
      2.times { |i| LimitedJob.perform_later(i) }
      assert_equal 2, claim(10).size

      SolidQueue::ScheduledExecution.update_all(scheduled_at: Time.current)
      SolidQueue::ScheduledExecution.dispatch_next_batch(10)
      assert_equal 1, claim(10).size
    end
  end

  test "a job whose class is missing, raises when it loads or isn't a job is claimed and fails as without the gem" do
    jobs = [ "SolidQueue::RateLimitClaimTest::MissingJob", "SolidQueue::RateLimitClaimTest::BrokenJob", "String" ].map do |class_name|
      UnlimitedJob.perform_later(class_name).tap do |active_job|
        job = SolidQueue::Job.find(active_job.provider_job_id)
        job.update_columns(class_name: class_name, arguments: job.arguments.merge("job_class" => class_name))
      end
    end

    claim(10).each { |execution| assert_raises(StandardError, ScriptError) { execution.perform } }

    assert_equal provider_ids(jobs), SolidQueue::FailedExecution.order(:job_id).pluck(:job_id)
  end

  test "workers with different settings share one budget, each applying its own" do
    2.times { |i| LimitedJob.perform_later(i) }
    assert_equal 2, claim(10).size

    # A deploy that loosens the limit: the old debt is clamped to the new burst
    LimitedJob.with(rate_limit_to: 10, rate_limit_burst: 10) do
      LimitedJob.perform_later(2)
      assert_equal 0, claim(10).size
      assert_equal Time.current + 1.second, SolidQueue::ScheduledExecution.sole.scheduled_at
    end

    # A worker still on the old limit allows more of the budget at once
    travel 1.second
    LimitedJob.perform_later(3)
    assert_equal 1, claim(10).size
  end

  test "a claim that deferred jobs looks again to fill its capacity" do
    4.times { |i| LimitedJob.perform_later(i) }
    unlimited = 3.times.map { |i| UnlimitedJob.perform_later(i) }

    claimed = claim(4)

    assert_equal 4, claimed.size
    assert_equal provider_ids(unlimited.first(2)), claimed.map(&:job_id).last(2)
  end

  test "a claim looks again at most 5 times" do
    LimitedJob.perform_later("spends the burst")
    LimitedJob.perform_later("spends the burst")
    claim(10)
    10.times { |i| LimitedJob.perform_later(i) }
    UnlimitedJob.perform_later("behind them")

    assert_empty claim(1)
    assert_equal 5, SolidQueue::ScheduledExecution.count
  end

  test "a claim inside a transaction looks only once" do
    4.times { |i| LimitedJob.perform_later(i) }
    UnlimitedJob.perform_later("unlimited")

    claimed = SolidQueue::ReadyExecution.transaction { claim(3) }

    assert_equal 2, claimed.size
  end

  test "a deadlock while looking again returns what was claimed before it" do
    limited = 3.times.map { |i| LimitedJob.perform_later(i) }
    UnlimitedJob.perform_later("unlimited")
    candidates = SolidQueue::ReadyExecution.ordered.limit(3).select(:id, :job_id).to_a
    SolidQueue::ReadyExecution.stubs(:select_candidates).returns(candidates).then.raises(ActiveRecord::Deadlocked)

    assert_equal provider_ids(limited.first(2)), claim(3).map(&:job_id)
  end

  test "a deadlock in a claim's first look raises" do
    LimitedJob.perform_later(0)
    SolidQueue::ReadyExecution.stubs(:select_candidates).raises(ActiveRecord::Deadlocked)

    assert_raises(ActiveRecord::Deadlocked) { claim(3) }
  end

  test "without any limit declared, an eager-loaded app claims with exactly Solid Queue's queries" do
    UnlimitedJob.perform_later(0)
    Rails.application.config.stubs(:eager_load).returns(true)

    queries = SolidQueue::RateLimit.with(declared: false) { capture_queries { claim(3) } }

    assert_equal [ "SolidQueue::Pause Pluck", "TRANSACTION", "SolidQueue::ReadyExecution Load", "SolidQueue::ClaimedExecution Insert", "SolidQueue::ClaimedExecution Load", "SolidQueue::ReadyExecution Delete All", "TRANSACTION" ], queries
  end

  private
    def capture_queries(&block)
      queries = []
      subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") { |event| queries << event.payload[:name] }
      block.call
      queries
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end

    def claim(limit)
      SolidQueue::ReadyExecution.claim("*", limit, @process.id)
    end

    def provider_ids(active_jobs)
      active_jobs.map(&:provider_job_id)
    end
end
