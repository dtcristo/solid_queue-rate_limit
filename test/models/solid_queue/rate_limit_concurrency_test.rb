# frozen_string_literal: true

require "test_helper"

# Several claiming threads and a dispatcher, on real time and the real database
class SolidQueue::RateLimitConcurrencyTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  class TenASecondJob < ApplicationJob
    limits_rate to: 10, per: 1.second, burst: 3

    def perform; end
  end

  class FiveASecondJob < ApplicationJob
    limits_rate to: 5, per: 1.second, burst: 2

    def perform; end
  end

  # Two classes sharing a group, with a budget for each key
  class GroupedJob < ApplicationJob
    limits_rate to: 5, per: 1.second, burst: 2, group: "Grouped", key: ->(account) { account }

    def perform(account); end
  end

  class OtherGroupedJob < GroupedJob; end

  class UnlimitedJob < ApplicationJob
    def perform; end
  end

  # Records the time each admission was charged at, in the thread that charged it.
  # A claim starts some time after that, so timing claims would misjudge the rate.
  module RecordAdmissions
    def admit(interval, burst, now)
      super.tap { |admitted| Thread.current[:rate_limit_admissions]&.push([ key, now ]) if admitted }
    end
  end

  SolidQueue::RateLimitState.prepend RecordAdmissions

  WORKERS = 6
  CAPACITY = 3

  setup do
    @processes = Array.new(WORKERS) { |i| SolidQueue::Process.register(kind: "Worker", pid: 42, name: "rate-limit-concurrency-worker-#{i}") }
    @claims = Queue.new
    @admissions = Queue.new

    @claim_subscriber = ActiveSupport::Notifications.subscribe("claim.solid_queue") do |*, payload|
      payload[:claimed_job_ids].each { |job_id| @claims << job_id }
    end

    # Only admissions that commit charge the limit
    @transaction_subscriber = ActiveSupport::Notifications.subscribe("transaction.active_record") do |*, payload|
      if (admissions = Thread.current[:rate_limit_admissions])
        admissions.each { |admission| @admissions << admission } if payload[:outcome] == :commit
        admissions.clear
      end
    end
  end

  teardown do
    ActiveSupport::Notifications.unsubscribe(@claim_subscriber)
    ActiveSupport::Notifications.unsubscribe(@transaction_subscriber)
  end

  test "claiming threads and a dispatcher keep every limit, and claim every job once" do
    job_classes = enqueue_jobs

    errors = run_workers_and_dispatcher(until_done: job_classes.size, timeout: 15.seconds)

    assert_empty errors
    assert_claimed_once_within_limits job_classes
  end

  # Claims open IMMEDIATE transactions on Rails 8, but another connection can still
  # hold a deferred one that starts as a reader and then needs the write lock.
  if ENV["TARGET_DB"] == "sqlite"
    test "claims wait out SQLite transactions that upgrade from reader to writer" do
      job_classes = enqueue_jobs
      upgrades = Concurrent::AtomicFixnum.new
      stop = Concurrent::AtomicBoolean.new

      upgrader = Thread.new do
        SolidQueue::Record.connection_pool.with_connection do |connection|
          until stop.true?
            begin
              connection.execute("BEGIN DEFERRED TRANSACTION")
              connection.select_value("SELECT COUNT(*) FROM solid_queue_ready_executions")
              sleep 0.005
              connection.execute("INSERT INTO solid_queue_pauses (queue_name, created_at) VALUES ('contention', CURRENT_TIMESTAMP)")
              upgrades.increment
            rescue ActiveRecord::StatementInvalid
              # This transaction is the one SQLite refuses, not the claims
            ensure
              connection.execute("ROLLBACK TRANSACTION") rescue nil
            end
          end
        end
      end

      errors = run_workers_and_dispatcher(until_done: job_classes.size, timeout: 15.seconds)
      stop.make_true
      upgrader.join

      assert_operator upgrades.value, :>, 0
      assert_empty errors
      assert_claimed_once_within_limits job_classes
      assert SolidQueue::Pause.none?
    end
  end

  private
    # Two limited classes in overlapping batches, and unlimited jobs among them.
    # One limit's state exists already, and the other's is created by the claims.
    def enqueue_jobs
      SolidQueue::RateLimitState.create!(key: TenASecondJob.name, tat: Time.current)

      ActiveJob.perform_all_later(Array.new(30) { TenASecondJob.new } + Array.new(15) { FiveASecondJob.new } + Array.new(30) { UnlimitedJob.new })
      ActiveJob.perform_all_later(Array.new(30) { [ TenASecondJob.new, FiveASecondJob.new, UnlimitedJob.new ].sample })
      ActiveJob.perform_all_later(Array.new(20) { |i| [ GroupedJob, OtherGroupedJob ][i % 2].new(%w[ a b ][i / 10]) })

      SolidQueue::Job.pluck(:id, :class_name).to_h
    end

    def assert_claimed_once_within_limits(job_classes)
      claims = Array.new(@claims.size) { @claims.pop }
      admissions = Array.new(@admissions.size) { @admissions.pop }

      assert_equal job_classes.keys.sort, claims.sort, "every job is claimed exactly once"
      assert SolidQueue::Job.where(finished_at: nil).none?

      { TenASecondJob.name => TenASecondJob, FiveASecondJob.name => FiveASecondJob, "Grouped/a" => GroupedJob, "Grouped/b" => GroupedJob }.each do |key, job_class|
        times = admissions.select { |admitted_key, _| admitted_key == key }.map(&:last).sort
        expected = key.start_with?("Grouped") ? 10 : job_classes.values.count(job_class.name)
        assert_equal expected, times.size, "#{key} is admitted once for each job"
        assert_within_rate job_class, times
        assert_operator times.last - times.first, :<=, (times.size - job_class.rate_limit_burst) * job_class.rate_limit_interval + 3, "#{key} drains in bounded time"
      end
    end

    def run_workers_and_dispatcher(until_done:, timeout:)
      errors = Queue.new
      claimed = Concurrent::AtomicFixnum.new
      deadline = Time.current + timeout
      running = -> { claimed.value < until_done && Time.current < deadline }

      workers = @processes.map do |process|
        Thread.new do
          Thread.current[:rate_limit_admissions] = []

          SolidQueue::Record.connection_pool.with_connection do
            while running.call
              begin
                executions = SolidQueue::ReadyExecution.claim("*", CAPACITY, process.id)
                executions.each(&:perform)
                claimed.increment(executions.size)
              rescue => error
                errors << error
              end
              sleep 0.01
            end
          end
        end
      end

      dispatcher = Thread.new do
        SolidQueue::Record.connection_pool.with_connection do
          while running.call
            begin
              SolidQueue::ScheduledExecution.dispatch_next_batch(500)
            rescue => error
              errors << error
            end
            sleep 0.1
          end
        end
      end

      (workers + [ dispatcher ]).each(&:join)

      Array.new(errors.size) { errors.pop }.map { |error| "#{error.class}: #{error.message}" }
    end

    # GCRA admits at most burst + floor(w / T) in any window of length w. It's
    # exact, so it's checked in rationals.
    def assert_within_rate(job_class, times)
      times.each_with_index do |first, i|
        times.each_with_index.drop(i + 1).each do |last, j|
          allowed = job_class.rate_limit_burst + ((last.to_r - first.to_r) / job_class.rate_limit_interval).floor
          assert_operator j - i + 1, :<=, allowed, "#{job_class.name} admitted #{j - i + 1} jobs in #{(last - first).round(3)}s"
        end
      end
    end
end
