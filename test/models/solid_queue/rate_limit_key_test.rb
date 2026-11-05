# frozen_string_literal: true

require "test_helper"

class SolidQueue::RateLimitKeyTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  class PerAccountJob < ApplicationJob
    limits_rate to: 1, per: 10.seconds, key: ->(account) { account }

    def perform(account); end
  end

  class ClassLimitedJob < ApplicationJob
    limits_rate to: 1, per: 10.seconds, key: :global

    def perform; end
  end

  class StripeChargeJob < ApplicationJob
    limits_rate to: 1, per: 10.seconds, group: "Stripe", key: :global

    def perform(account); end
  end

  class PerAccountChildJob < PerAccountJob; end

  class StripeChargeChildJob < StripeChargeJob; end

  class StripeRefundJob < ApplicationJob
    limits_rate to: 1, per: 10.seconds, group: :Stripe, key: :global

    def perform(account); end
  end

  class StripeAccountChargeJob < ApplicationJob
    limits_rate to: 1, per: 10.seconds, group: "StripeAccount", key: ->(account) { account }

    def perform(account); end
  end

  class StripeAccountRefundJob < ApplicationJob
    limits_rate to: 1, per: 10.seconds, group: ->(*) { "StripeAccount" }, key: ->(account) { account }

    def perform(account); end
  end

  class OptionalAccountJob < ApplicationJob
    limits_rate to: 1, per: 10.seconds, key: ->(account) { account }

    def perform(account); end
  end

  class OptionalStripeAccountJob < ApplicationJob
    limits_rate to: 1, per: 10.seconds, group: "Stripe", key: ->(account) { account }

    def perform(account); end
  end

  class RaisingKeyJob < ApplicationJob
    limits_rate to: 1, per: 10.seconds, key: ->(*) { raise ExpectedTestError }

    def perform; end
  end

  class RetryingJob < ApplicationJob
    mattr_accessor :keys_computed, default: 0

    limits_rate to: 1, per: 10.seconds, key: ->(account) { self.class.keys_computed += 1; account }
    retry_on ExpectedTestError, wait: 0, attempts: 2

    def perform(account)
      raise ExpectedTestError if executions == 1
    end
  end

  # Without its arguments, the key's lambda would raise on a retry
  class RecordKeyJob < ApplicationJob
    limits_rate to: 1, per: 10.seconds, key: ->(record) { record }
    retry_on ActiveJob::DeserializationError, wait: 0, attempts: 2

    def perform(record); end
  end

  class FailingJob < ApplicationJob
    limits_rate to: 1, per: 10.seconds, key: ->(account) { account }

    def perform(account)
      raise ExpectedTestError
    end
  end

  setup do
    travel_to Time.utc(2026, 1, 1, 12)
    @process = SolidQueue::Process.register(kind: "Worker", pid: 42, name: "rate-limit-key-test-worker")
  end

  teardown do
    travel_back
  end

  test "each key has a budget of its own" do
    jobs = [ PerAccountJob.perform_later("a"), PerAccountJob.perform_later("a"), PerAccountJob.perform_later("b") ]

    assert_equal provider_ids([ jobs.first, jobs.third ]), claim.map(&:job_id)
    assert_equal [ jobs.second.provider_job_id ], SolidQueue::ScheduledExecution.pluck(:job_id)
  end

  test "each key staggers its own waiting jobs" do
    jobs = %w[ a a a b b ].map { |account| PerAccountJob.perform_later(account) }

    claim

    scheduled = SolidQueue::ScheduledExecution.pluck(:job_id, :scheduled_at).to_h
    assert_equal [ 10, 20, 10 ], jobs.values_at(1, 2, 4).map { |job| scheduled[job.provider_job_id] - Time.current }
  end

  test "a subclass without a group of its own has its own budget for each key" do
    jobs = [ PerAccountJob.perform_later("a"), PerAccountChildJob.perform_later("a"), PerAccountChildJob.perform_later("a") ]

    assert_equal provider_ids(jobs.first(2)), claim.map(&:job_id)
  end

  test "a subclass shares the group it inherits" do
    jobs = [ StripeChargeJob.perform_later("a"), StripeChargeChildJob.perform_later("a") ]

    assert_equal [ jobs.first.provider_job_id ], claim.map(&:job_id)
  end

  test "classes in a group share its budget" do
    jobs = [ StripeChargeJob.perform_later("a"), StripeRefundJob.perform_later("b") ]

    assert_equal [ jobs.first.provider_job_id ], claim.map(&:job_id)
    assert_equal [ jobs.second.provider_job_id ], SolidQueue::ScheduledExecution.pluck(:job_id)
  end

  test "classes in a group with a key share each key's budget" do
    jobs = [ StripeAccountChargeJob.perform_later("a"), StripeAccountRefundJob.perform_later("a"), StripeAccountRefundJob.perform_later("b") ]

    assert_equal provider_ids([ jobs.first, jobs.third ]), claim.map(&:job_id)
    assert_equal [ jobs.second.provider_job_id ], SolidQueue::ScheduledExecution.pluck(:job_id)
  end

  test "a record as the key shares a budget with the same record" do
    first, second = JobResult.create!, JobResult.create!
    jobs = [ PerAccountJob.perform_later(first), PerAccountJob.perform_later(JobResult.find(first.id)), PerAccountJob.perform_later(second) ]

    assert_equal provider_ids([ jobs.first, jobs.third ]), claim.map(&:job_id)
  ensure
    JobResult.delete_all
  end

  test "a nil key falls back to the class's budget" do
    jobs = [ OptionalAccountJob.perform_later(nil), OptionalAccountJob.perform_later(nil), OptionalAccountJob.perform_later("a") ]

    assert_equal provider_ids([ jobs.first, jobs.third ]), claim.map(&:job_id)
  end

  test "a nil key in a group falls back to the group's budget" do
    jobs = [ OptionalStripeAccountJob.perform_later(nil), OptionalStripeAccountJob.perform_later(nil), OptionalStripeAccountJob.perform_later("a") ]

    assert_equal provider_ids([ jobs.first, jobs.third ]), claim.map(&:job_id)
    assert_equal [ "Stripe", "Stripe/a" ], SolidQueue::RateLimitState.pluck(:key).sort
  end

  test "keys are built the way limits_concurrency builds its key" do
    result = JobResult.create!

    [ [ "literal", [] ], [ :literal, [] ], [ ->(name) { name }, [ "a" ] ], [ ->(record) { record }, [ result ] ], [ ->(*) { nil }, [] ], [ "", [] ], [ 42, [] ] ].each do |key, arguments|
      [ {}, { group: "Stripe" }, { group: nil } ].each do |group|
        job_class = Class.new(ApplicationJob) do
          def self.name = "ParityJob"

          limits_rate to: 1, per: 1.second, key: key, **group
          limits_concurrency key: key, **group
        end

        assert_equal job_class.new(*arguments).concurrency_key, job_class.new(*arguments).rate_limit_key
      end
    end
  ensure
    JobResult.delete_all
  end

  test "a key that comes out blank isn't limited, as a blank concurrency key isn't" do
    [ { group: ->(*) { }, key: ->(*) { } }, { group: nil, key: ->(*) { } } ].each do |options|
      job_class = rate_limited_job("BlankKeyJob", **options)
      jobs = 2.times.map { job_class.perform_later }

      assert_equal provider_ids(jobs), claim.map(&:job_id)
      assert_empty SolidQueue::RateLimitState.all
    end
  end

  test "a deferral instruments the keys it deferred, once for each class" do
    jobs = %w[ a a a b b c ].map { |account| PerAccountJob.perform_later(account) }
    events = []
    subscriber = ActiveSupport::Notifications.subscribe("defer_rate_limited.solid_queue") { |event| events << event.payload }

    claim

    assert_equal [ { class_name: PerAccountJob.name, keys: [ "#{PerAccountJob.name}/a", "#{PerAccountJob.name}/b" ], job_ids: provider_ids(jobs.values_at(1, 2, 4)), size: 3 } ], events
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end

  test "a key that raises fails the enqueue" do
    assert_raises(ExpectedTestError) { RaisingKeyJob.perform_later }
    assert_raises(ExpectedTestError) { ActiveJob.perform_all_later(RaisingKeyJob.new) }
    assert_equal 0, SolidQueue::Job.count
  end

  test "perform_now and other adapters never compute the key" do
    assert_nothing_raised { RaisingKeyJob.perform_now }

    job_class = Class.new(RaisingKeyJob) { self.queue_adapter = :test }
    assert_nothing_raised { job_class.perform_later }
  end

  test "a key longer than the state table allows fails the enqueue, like an over-long concurrency key" do
    long = "a" * 300

    if SolidQueue::Record.connection.adapter_name.match?(/mysql/i)
      error = assert_raises(SolidQueue::Job::EnqueueError) { PerAccountJob.perform_later(long) }
      assert_match(/ActiveRecord::ValueTooLong/, error.message)
      assert_raises(ActiveRecord::ValueTooLong) { ActiveJob.perform_all_later(PerAccountJob.new(long)) }
      assert_equal 0, SolidQueue::Job.count
    else
      jobs = [ PerAccountJob.perform_later(long), PerAccountJob.perform_later(long) ]
      assert_equal [ jobs.first.provider_job_id ], claim.map(&:job_id)
    end
  end

  test "a job enqueued without a key, as by 0.1.0, uses the class's budget" do
    old = 2.times.map { PerAccountJob.perform_later("a") }
    without_stored_keys(old)
    new = PerAccountJob.perform_later("a")

    assert_equal provider_ids([ old.first, new ]), claim.map(&:job_id)
    assert_equal [ PerAccountJob.name, "#{PerAccountJob.name}/a" ], SolidQueue::RateLimitState.pluck(:key).sort
  end

  test "a job without a key gets its class's current key when it's serialized again" do
    job = PerAccountJob.new("a")
    job.deserialize(job.serialize.except(ActiveJob::RateControls::RATE_LIMIT_KEY))

    assert_equal "#{PerAccountJob.name}/a", job.serialize[ActiveJob::RateControls::RATE_LIMIT_KEY]
  end

  test "a waiting job keeps the key it was enqueued with when its class changes the key" do
    PerAccountJob.perform_later("a")
    PerAccountJob.perform_later("b")

    PerAccountJob.with(rate_limit_key: :global) { assert_equal 2, claim.size }
  end

  test "a class that turns its limit off has its jobs claimed" do
    PerAccountJob.perform_later("a")
    PerAccountJob.perform_later("a")

    PerAccountJob.with(rate_limit_key: nil) { assert_equal 2, claim.size }
  end

  test "a retry from retry_on keeps its key" do
    RetryingJob.keys_computed = 0
    RetryingJob.perform_later("a")
    claim.each(&:perform)

    assert_empty claim
    assert_equal 1, SolidQueue::ScheduledExecution.count
    assert_equal 1, RetryingJob.keys_computed
  end

  test "a retry after the arguments failed to deserialize keeps its key" do
    record = JobResult.create!
    RecordKeyJob.perform_later(record)
    record.destroy

    claim.each(&:perform)

    assert_equal 1, SolidQueue::ReadyExecution.count
    assert_empty claim
    assert_equal 1, SolidQueue::ScheduledExecution.count
  ensure
    JobResult.delete_all
  end

  test "retrying a failed job keeps its key" do
    FailingJob.perform_later("a")
    assert_raises(ExpectedTestError) { claim.each(&:perform) }
    FailingJob.perform_later("b")

    SolidQueue::FailedExecution.sole.retry

    assert_equal [ "b" ], claim.map { |execution| execution.job.arguments["arguments"].sole }
  end

  test "a claim reads the stored keys of limited jobs only, in one query" do
    limited = [ PerAccountJob.perform_later("a"), StripeChargeJob.perform_later("b"), ClassLimitedJob.perform_later ]
    unlimited = [ AddToBufferJob.perform_later("unlimited") ]

    # Payloads that can't be parsed fail any claim that reads them
    SolidQueue::Job.where(id: provider_ids(unlimited)).update_all("arguments = '{'")

    queries = capture_queries { assert_equal provider_ids(limited + unlimited).sort, claim.map(&:job_id).sort }

    assert_equal 1, queries.count("SolidQueue::Job Pluck")
  end

  test "a key that isn't a String, Symbol or Proc is nil, as in limits_concurrency" do
    job_class = rate_limited_job("IntegerKeyJob", key: 42)
    jobs = 2.times.map { job_class.perform_later }

    assert_equal [ jobs.first.provider_job_id ], claim.map(&:job_id)
    assert_equal [ job_class.name ], SolidQueue::RateLimitState.pluck(:key)
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

    def without_stored_keys(active_jobs)
      SolidQueue::Job.where(id: provider_ids(active_jobs)).each do |job|
        job.update!(arguments: job.arguments.except(ActiveJob::RateControls::RATE_LIMIT_KEY))
      end
    end

    def rate_limited_job(name, **options)
      self.class.send(:remove_const, name) if self.class.const_defined?(name, false)
      self.class.const_set(name, Class.new(ApplicationJob) { limits_rate(to: 1, per: 10.seconds, **options) })
    end

    def claim(limit = 10)
      SolidQueue::ReadyExecution.claim("*", limit, @process.id)
    end

    def provider_ids(active_jobs)
      active_jobs.map(&:provider_job_id)
    end
end
