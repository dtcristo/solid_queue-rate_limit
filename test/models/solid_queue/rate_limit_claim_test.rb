# frozen_string_literal: true

require "test_helper"

class SolidQueue::RateLimitClaimTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  class LimitedJob < ApplicationJob
    limits_rate to: 1, per: 10.seconds, burst: 2, key: :global

    def perform(value)
      JobBuffer.add(value)
    end
  end

  class CasedJob < ApplicationJob
    limits_rate to: 1, per: 10.seconds, key: :global

    def perform; end
  end

  class CASEDJob < ApplicationJob
    limits_rate to: 1, per: 10.seconds, key: :global

    def perform; end
  end

  # Kept after a rename, for jobs enqueued under the old name
  RenamedLimitedJob = LimitedJob

  class UnlimitedJob < ApplicationJob
    def perform(value)
      JobBuffer.add(value)
    end
  end

  # One at a time, with a budget for each account
  class SyncAccountJob < ApplicationJob
    limits_concurrency key: ->(*) { "all" }
    limits_rate to: 1, per: 10.seconds, key: ->(account) { account }

    def perform(account)
      JobBuffer.add(account)
    end
  end

  # Not a job, whatever it says about itself
  class NotAJob
    def self.rate_limited?
      true
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

  test "a deferral instruments defer_rate_limited for each class" do
    jobs = 3.times.map { |i| LimitedJob.perform_later(i) }
    events = []
    subscriber = ActiveSupport::Notifications.subscribe("defer_rate_limited.solid_queue") { |event| events << event.payload }

    claim(10)

    assert_equal [ { class_name: LimitedJob.name, keys: [ "#{LimitedJob.name}/global" ], job_ids: [ jobs.last.provider_job_id ], size: 1 } ], events
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
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

  test "a job enqueued under an old name shares its class's budget" do
    jobs = 3.times.map { |i| LimitedJob.perform_later(i) }
    SolidQueue::Job.where(id: jobs.first.provider_job_id).update_all(class_name: "#{self.class.name}::RenamedLimitedJob")

    assert_equal provider_ids(jobs.first(2)), claim(10).map(&:job_id)
    assert_equal [ "#{LimitedJob.name}/global" ], SolidQueue::RateLimitState.pluck(:key)
  end

  test "a job the rate rejects wakes the next blocked job, which the claim can admit" do
    spend_budget_of("a")
    deferred = SyncAccountJob.perform_later("a")
    woken = SyncAccountJob.perform_later("b")
    events = []
    subscriber = ActiveSupport::Notifications.subscribe("release_blocked.solid_queue") { |event| events << event.payload.slice(:job_id, :released) }

    assert_equal [ woken.provider_job_id ], claim(10).map(&:job_id)
    assert_equal [ deferred.provider_job_id ], SolidQueue::ScheduledExecution.pluck(:job_id)
    assert_equal 0, SolidQueue::Semaphore.sole.value
    assert SolidQueue::BlockedExecution.none?
    assert_equal [ { job_id: woken.provider_job_id, released: true } ], events
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end

  test "a deferred job wakes the next blocked job once its deferral has committed" do
    spend_budget_of("a")
    deferred = SyncAccountJob.perform_later("a")
    SyncAccountJob.perform_later("b")
    committed = []
    subscriber = ActiveSupport::Notifications.subscribe("release_blocked.solid_queue") do
      committed << Thread.new { SolidQueue::Record.connection_pool.with_connection { SolidQueue::ScheduledExecution.exists?(job_id: deferred.provider_job_id) } }.value
    end

    claim(10)

    assert_equal [ true ], committed
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end

  test "a claim that fails after deferring gives no semaphore back, then or on its next claim" do
    spend_budget_of("a")
    deferred = SyncAccountJob.perform_later("a")
    blocked = SyncAccountJob.perform_later("b")
    failing = ->(*, payload) { raise ActiveRecord::StatementInvalid, "failed" if payload[:name] == "SolidQueue::ReadyExecution Delete All" }

    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record", failing)
    assert_raises(ActiveRecord::StatementInvalid) { claim(10) }
    ActiveSupport::Notifications.unsubscribe(subscriber)
    claim(0)

    assert_equal [ deferred.provider_job_id ], SolidQueue::ReadyExecution.pluck(:job_id)
    assert_equal [ blocked.provider_job_id ], SolidQueue::BlockedExecution.pluck(:job_id)
    assert_equal 0, SolidQueue::Semaphore.sole.value
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end

  test "a deadlock while waking a blocked job is logged, and the claim keeps what it deferred and gives the semaphore back" do
    spend_budget_of("a")
    deferred = SyncAccountJob.perform_later("a")
    blocked = SyncAccountJob.perform_later("b")
    unlimited = UnlimitedJob.perform_later("behind them")
    log = StringIO.new

    claimed = SolidQueue.with(logger: ActiveSupport::Logger.new(log)) do
      deadlocking_on("SolidQueue::ReadyExecution Create", occurrence: 1) { claim(10) }
    end

    assert_equal [ unlimited.provider_job_id ], claimed.map(&:job_id)
    assert_equal [ deferred.provider_job_id ], SolidQueue::ScheduledExecution.pluck(:job_id)
    assert_equal [ blocked.provider_job_id ], SolidQueue::BlockedExecution.pluck(:job_id)
    assert_equal 1, SolidQueue::Semaphore.sole.value
    assert_match(/ActiveRecord::Deadlocked/, log.string)
  end

  test "inside a transaction, rolling it back undoes the release, the wake and the deferral together" do
    spend_budget_of("a")
    deferred = SyncAccountJob.perform_later("a")
    woken = SyncAccountJob.perform_later("b")

    SolidQueue::ReadyExecution.transaction do
      claim(10)
      assert_equal [ woken.provider_job_id ], SolidQueue::ReadyExecution.pluck(:job_id)
      raise ActiveRecord::Rollback
    end

    assert_equal [ deferred.provider_job_id ], SolidQueue::ReadyExecution.pluck(:job_id)
    assert_equal [ woken.provider_job_id ], SolidQueue::BlockedExecution.pluck(:job_id)
    assert SolidQueue::ScheduledExecution.none?
    assert_equal 0, SolidQueue::Semaphore.sole.value
  end

  test "a deferred job that comes back takes a semaphore again" do
    spend_budget_of("a")
    returning = SyncAccountJob.perform_later("a")
    claim(10)

    travel 10.seconds
    assert_equal 1, SolidQueue::ScheduledExecution.dispatch_next_batch(10)
    assert_equal [ returning.provider_job_id ], SolidQueue::ReadyExecution.pluck(:job_id)
    assert_equal 0, SolidQueue::Semaphore.sole.value

    assert_equal [ returning.provider_job_id ], claim(10).map(&:job_id)
  end

  test "a deferred job that comes back while its semaphore is taken is blocked, and runs once it's free" do
    spend_budget_of("a")
    returning = SyncAccountJob.perform_later("a")
    claim(10)
    taking = SyncAccountJob.perform_later("b")

    travel 10.seconds
    SolidQueue::ScheduledExecution.dispatch_next_batch(10)
    assert_equal [ returning.provider_job_id ], SolidQueue::BlockedExecution.pluck(:job_id)

    assert_equal [ taking.provider_job_id ], claim(10).each(&:perform).map(&:job_id)
    assert_equal [ returning.provider_job_id ], claim(10).each(&:perform).map(&:job_id)
    assert_equal %w[ a b a ], JobBuffer.values
  end

  test "discarding a deferred job leaves its semaphore alone, once it's waiting and once it came back blocked" do
    spend_budget_of("a")
    deferred = SyncAccountJob.perform_later("a")
    claim(10)

    SolidQueue::Job.find(deferred.provider_job_id).discard
    assert_equal 1, SolidQueue::Semaphore.sole.value

    deferred = SyncAccountJob.perform_later("a")
    claim(10)
    SyncAccountJob.perform_later("b")
    SolidQueue::ScheduledExecution.update_all(scheduled_at: Time.current)
    SolidQueue::ScheduledExecution.dispatch_next_batch(10)
    assert_equal [ deferred.provider_job_id ], SolidQueue::BlockedExecution.pluck(:job_id)

    SolidQueue::Job.find(deferred.provider_job_id).discard
    assert_equal 0, SolidQueue::Semaphore.sole.value
  end

  test "a deferred job that recorded no semaphore gives none back" do
    spend_budget_of("a")
    deferred = SyncAccountJob.perform_later("a")
    update_concurrency_lock(deferred) { |arguments| arguments.merge(SolidQueue::Job::CONCURRENCY_LOCK_KEY => { "semaphore_id" => nil, "limit" => nil }) }

    claim(10)
    assert_equal 0, SolidQueue::Semaphore.sole.value
  end

  test "a deferred job dispatched before Solid Queue recorded its semaphore gives back its key's" do
    spend_budget_of("a")
    deferred = SyncAccountJob.perform_later("a")
    update_concurrency_lock(deferred) { |arguments| arguments.except(SolidQueue::Job::CONCURRENCY_LOCK_KEY) }

    claim(10)
    assert_equal 1, SolidQueue::Semaphore.sole.value
  end

  test "a deferred job whose semaphore expired and was replaced leaves the new one alone" do
    spend_budget_of("a")
    deferred = SyncAccountJob.perform_later("a")
    blocked = SyncAccountJob.perform_later("b")
    SolidQueue::Semaphore.delete_all
    SolidQueue::Semaphore.create!(key: SolidQueue::Job.find(deferred.provider_job_id).concurrency_key, value: 0, expires_at: 1.minute.from_now)

    assert_empty claim(10)
    assert_equal [ deferred.provider_job_id ], SolidQueue::ScheduledExecution.pluck(:job_id)
    assert_equal 0, SolidQueue::Semaphore.sole.value
    assert_equal [ blocked.provider_job_id ], SolidQueue::BlockedExecution.pluck(:job_id)
  end

  test "a deferred job wakes a blocked job whose class is missing, which fails as in Solid Queue" do
    spend_budget_of("a")
    SyncAccountJob.perform_later("a")
    missing = SyncAccountJob.perform_later("b")
    SolidQueue::Job.where(id: missing.provider_job_id).update_all(class_name: "#{self.class.name}::MissingJob")
    unlimited = UnlimitedJob.perform_later("behind them")

    assert_equal [ unlimited.provider_job_id ], claim(10).map(&:job_id)
    assert_equal [ missing.provider_job_id ], SolidQueue::FailedExecution.pluck(:job_id)
    assert_equal 1, SolidQueue::Semaphore.sole.value
  end

  test "a blocked job whose class raises when it loads stays blocked, and the claim gives the semaphore back and goes on" do
    spend_budget_of("a")
    SyncAccountJob.perform_later("a")
    broken = SyncAccountJob.perform_later("b")
    SolidQueue::Job.where(id: broken.provider_job_id).update_all(class_name: "#{self.class.name}::BrokenJob")
    unlimited = UnlimitedJob.perform_later("behind them")
    log = StringIO.new

    claimed = SolidQueue.with(logger: ActiveSupport::Logger.new(log)) { claim(10) }

    assert_equal [ unlimited.provider_job_id ], claimed.map(&:job_id)
    assert_equal [ broken.provider_job_id ], SolidQueue::BlockedExecution.pluck(:job_id)
    assert_equal 1, SolidQueue::Semaphore.sole.value
    assert_match(/SyntaxError: broken/, log.string)
  end

  test "a blocked job whose class raises when it loads doesn't stop a later look" do
    2.times { |i| LimitedJob.perform_later(i) }
    claim(10)
    spend_budget_of("a")
    deferred = [ LimitedJob.perform_later("first look"), SyncAccountJob.perform_later("a") ]
    broken = SyncAccountJob.perform_later("b")
    SolidQueue::Job.where(id: broken.provider_job_id).update_all(class_name: "#{self.class.name}::BrokenJob")
    unlimited = UnlimitedJob.perform_later("behind them")

    assert_equal [ unlimited.provider_job_id ], SolidQueue.with(logger: ActiveSupport::Logger.new(nil)) { claim(1) }.map(&:job_id)
    assert_equal provider_ids(deferred), SolidQueue::ScheduledExecution.order(:job_id).pluck(:job_id)
    assert_equal [ broken.provider_job_id ], SolidQueue::BlockedExecution.pluck(:job_id)
  end

  test "a job that still has a concurrency key after its class dropped limits_concurrency is rate-checked" do
    jobs = 3.times.map { |i| LimitedJob.perform_later(i) }
    SolidQueue::Job.update_all(concurrency_key: "switched from limits_concurrency")

    assert_equal provider_ids(jobs.first(2)), claim(10).map(&:job_id)
    assert_equal [ jobs.last.provider_job_id ], SolidQueue::ScheduledExecution.pluck(:job_id)
  end

  test "a job the rate admits keeps its semaphore" do
    admitted = SyncAccountJob.perform_later("a")
    blocked = SyncAccountJob.perform_later("b")

    assert_equal [ admitted.provider_job_id ], claim(10).map(&:job_id)
    assert_equal 0, SolidQueue::Semaphore.sole.value
    assert_equal [ blocked.provider_job_id ], SolidQueue::BlockedExecution.pluck(:job_id)
  end

  test "a job the rate rejects gives its semaphore back and waits as a scheduled job" do
    spend_budget_of("a")
    deferred = SyncAccountJob.perform_later("a")
    assert_equal 0, SolidQueue::Semaphore.sole.value

    assert_empty claim(10)
    assert_equal [ deferred.provider_job_id ], SolidQueue::ScheduledExecution.pluck(:job_id)
    assert_equal 1, SolidQueue::Semaphore.sole.value
  end

  test "a class that dropped its limit has its jobs claimed, deferred ones included" do
    3.times { |i| LimitedJob.perform_later(i) }
    claim(10)

    LimitedJob.with(rate_limit_key: nil) do
      2.times { |i| LimitedJob.perform_later(i) }
      assert_equal 2, claim(10).size

      SolidQueue::ScheduledExecution.update_all(scheduled_at: Time.current)
      SolidQueue::ScheduledExecution.dispatch_next_batch(10)
      assert_equal 1, claim(10).size
    end
  end

  test "a job whose class is missing, raises when it loads or isn't a job is claimed and fails as without the gem" do
    jobs = [ "SolidQueue::RateLimitClaimTest::MissingJob", "SolidQueue::RateLimitClaimTest::BrokenJob", "String", "SolidQueue::RateLimitClaimTest::NotAJob" ].map do |class_name|
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

  test "a deadlock while looking again returns what was claimed before it, and rolls back only its own pass" do
    limited = 4.times.map { |i| LimitedJob.perform_later(i) }

    claimed = deadlocking_on("SolidQueue::ScheduledExecution Insert", occurrence: 2) { claim(3) }

    assert_equal provider_ids(limited.first(2)), claimed.map(&:job_id)
    assert_equal [ limited.third.provider_job_id ], SolidQueue::ScheduledExecution.pluck(:job_id)
    assert_equal [ limited.fourth.provider_job_id ], SolidQueue::ReadyExecution.pluck(:job_id)
    assert_equal Time.current + 10.seconds, SolidQueue::RateLimitState.sole.deferred_until
  end

  test "a deadlock in a claim's first look rolls it back and looks once more" do
    limited = 3.times.map { |i| LimitedJob.perform_later(i) }

    claimed = deadlocking_on("SolidQueue::ScheduledExecution Insert", occurrence: 1) { claim(3) }

    assert_equal provider_ids(limited.first(2)), claimed.map(&:job_id)
    assert_equal [ limited.third.provider_job_id ], SolidQueue::ScheduledExecution.pluck(:job_id)
    assert_equal Time.current + 10.seconds, SolidQueue::RateLimitState.sole.deferred_until
  end

  test "a second deadlock in a claim's first look raises and rolls it back" do
    3.times { |i| LimitedJob.perform_later(i) }

    assert_raises(ActiveRecord::Deadlocked) do
      deadlocking_on("SolidQueue::ScheduledExecution Insert", occurrence: 1..2) { claim(3) }
    end

    assert_equal 3, SolidQueue::ReadyExecution.count
    assert_equal 0, SolidQueue::ClaimedExecution.count
    assert_equal 0, SolidQueue::RateLimitState.count
  end

  test "a deadlock in a dispatch rolls it back and dispatches once more" do
    jobs = 2.times.map { |i| LimitedJob.set(wait: 1.minute).perform_later(i) }
    travel 1.minute

    dispatched = deadlocking_on(/\ASolidQueue::ReadyExecution (Bulk )?Insert\z/, occurrence: 1) { SolidQueue::ScheduledExecution.dispatch_next_batch(10) }

    assert_equal 2, dispatched
    assert_equal provider_ids(jobs).sort, SolidQueue::ReadyExecution.pluck(:job_id).sort
    assert SolidQueue::ScheduledExecution.none?
  end

  test "a second deadlock in a dispatch raises and rolls it back" do
    2.times { |i| LimitedJob.set(wait: 1.minute).perform_later(i) }
    travel 1.minute

    assert_raises(ActiveRecord::Deadlocked) do
      deadlocking_on(/\ASolidQueue::ReadyExecution (Bulk )?Insert\z/, occurrence: 1..2) { SolidQueue::ScheduledExecution.dispatch_next_batch(10) }
    end

    assert SolidQueue::ReadyExecution.none?
    assert_equal 2, SolidQueue::ScheduledExecution.count
  end

  test "classes whose names differ only in case can be claimed together" do
    jobs = [ CasedJob.perform_later, CASEDJob.perform_later ]

    claimed = claim(10)

    # MySQL's default collation compares keys without case, so there they share a budget
    expected = SolidQueue::Record.connection.adapter_name.match?(/mysql/i) ? jobs.first(1) : jobs
    assert_equal provider_ids(expected), claimed.map(&:job_id)
  end

  test "without any limit declared, an eager-loaded app claims with exactly Solid Queue's queries" do
    UnlimitedJob.perform_later(0)
    Rails.application.config.stubs(:eager_load).returns(true)

    queries = SolidQueue::RateLimit.with(declared: false) { capture_queries { claim(3) } }

    assert_equal [ "SolidQueue::Pause Pluck", "TRANSACTION", "SolidQueue::ReadyExecution Load", "SolidQueue::ClaimedExecution Insert", "SolidQueue::ClaimedExecution Load", "SolidQueue::ReadyExecution Delete All", "TRANSACTION" ], queries
  end

  test "a claim reads the stored keys of limited jobs in one query" do
    3.times { |i| LimitedJob.perform_later(i) }
    SolidQueue::RateLimitState.create!(key: "#{LimitedJob.name}/global", tat: Time.current)

    queries = capture_queries { claim(10) }

    assert_equal [ "SolidQueue::Pause Pluck", "TRANSACTION", "SolidQueue::ReadyExecution Load", "SolidQueue::Job Load", "SolidQueue::Job Pluck", "SolidQueue::RateLimitState Pluck", "SolidQueue::RateLimitState Load", "SolidQueue::RateLimitState Update", "SolidQueue::ScheduledExecution Insert", "SolidQueue::ClaimedExecution Bulk Insert", "SolidQueue::ClaimedExecution Load", "SolidQueue::ReadyExecution Delete All", "SolidQueue::ReadyExecution Delete All", "TRANSACTION", "TRANSACTION", "SolidQueue::ReadyExecution Load", "TRANSACTION" ], queries
  end

  private
    # Raises once the given query has run, as InnoDB or PostgreSQL would for a deadlock victim
    def deadlocking_on(query_name, occurrence:, &block)
      seen = 0
      subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
        raise ActiveRecord::Deadlocked, "Deadlock found" if query_name === payload[:name] && Array(occurrence).include?(seen += 1)
      end
      block.call
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end

    # Schema queries depend on which test loaded a model's columns first
    def capture_queries(&block)
      queries = []
      subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") { |event| queries << event.payload[:name] unless event.payload[:name] == "SCHEMA" }
      block.call
      queries
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end

    # Runs a job, which spends the account's budget and gives its slot back
    def spend_budget_of(account)
      SyncAccountJob.perform_later(account)
      claim(10).each(&:perform)
    end

    def update_concurrency_lock(active_job)
      job = SolidQueue::Job.find(active_job.provider_job_id)
      job.update_column(:arguments, yield(job.arguments))
    end

    def claim(limit)
      SolidQueue::ReadyExecution.claim("*", limit, @process.id)
    end

    def provider_ids(active_jobs)
      active_jobs.map(&:provider_job_id)
    end
end
