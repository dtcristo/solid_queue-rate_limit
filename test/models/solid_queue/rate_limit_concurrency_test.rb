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

  class UnlimitedJob < ApplicationJob
    def perform; end
  end

  WORKERS = 6
  CAPACITY = 3

  # Claims are timed in the claim's transaction, a moment after the limit's time is
  # read, so two measured claims can be a little closer than they were admitted.
  MEASUREMENT_TOLERANCE = 0.02

  setup do
    @processes = Array.new(WORKERS) { |i| SolidQueue::Process.register(kind: "Worker", pid: 42, name: "rate-limit-concurrency-worker-#{i}") }
    @claims = Queue.new
    @subscriber = ActiveSupport::Notifications.subscribe("claim.solid_queue") do |_name, start, _finish, _id, payload|
      payload[:claimed_job_ids].each { |job_id| @claims << [ job_id, start ] }
    end
  end

  teardown do
    ActiveSupport::Notifications.unsubscribe(@subscriber)
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

      SolidQueue::Job.pluck(:id, :class_name).to_h
    end

    def assert_claimed_once_within_limits(job_classes)
      claims = Array.new(@claims.size) { @claims.pop }

      assert_equal job_classes.keys.sort, claims.map(&:first).sort, "every job is claimed exactly once"
      assert SolidQueue::Job.where(finished_at: nil).none?

      [ TenASecondJob, FiveASecondJob ].each do |job_class|
        times = claims.select { |job_id, _| job_classes[job_id] == job_class.name }.map(&:last).sort
        assert_within_rate job_class, times
        assert_operator times.last - times.first, :<=, (times.size - job_class.rate_limit_burst) * job_class.rate_limit_interval + 3, "#{job_class.name} drains in bounded time"
      end
    end

    def run_workers_and_dispatcher(until_done:, timeout:)
      errors = Queue.new
      claimed = Concurrent::AtomicFixnum.new
      deadline = Time.current + timeout
      running = -> { claimed.value < until_done && Time.current < deadline }

      workers = @processes.map do |process|
        Thread.new do
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

    # GCRA admits at most burst + floor(w / T) in any window of length w
    def assert_within_rate(job_class, times)
      interval = job_class.rate_limit_interval.to_f

      times.each_with_index do |first, i|
        times.each_with_index.drop(i + 1).each do |last, j|
          allowed = job_class.rate_limit_burst + ((last - first + MEASUREMENT_TOLERANCE) / interval).floor
          assert_operator j - i + 1, :<=, allowed, "#{job_class.name} claimed #{j - i + 1} jobs in #{(last - first).round(3)}s"
        end
      end
    end
end
