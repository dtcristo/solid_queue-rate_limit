# frozen_string_literal: true

require "test_helper"
require_relative "../../../lib/generators/solid_queue/rate_limit/install/templates/db/create_solid_queue_rate_limits"

class SolidQueue::RateLimitPendingMigrationsTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  class LimitedJob < ApplicationJob
    limits_rate to: 1, per: 1.minute, burst: 2

    def perform(value)
      JobBuffer.add(value)
    end
  end

  class CoalescedLimitedJob < ApplicationJob
    coalesce key: ->(value) { value }
    limits_rate to: 1, per: 1.minute

    def perform(value); end
  end

  class CollectingLimitedJob < ApplicationJob
    coalesce key: ->(value) { value }, on_conflict: :collect
    limits_rate to: 1, per: 1.minute

    def perform_calls(calls); end
  end

  # Recreate an app that hasn't run the optional migration by reverting the
  # actual migration that ships with the install generator.
  setup do
    migrate(:down)
  end

  teardown do
    migrate(:up)
    destroy_records
  end

  test "the rate limiting schema counts as pending migrations" do
    assert_not SolidQueue::RateLimitState.migrated?
  end

  test "enqueueing a limited job raises a clear error, single or bulk" do
    error = assert_raises(SolidQueue::RateLimitState::PendingMigrations) { LimitedJob.perform_later("a") }
    assert_match(/solid_queue:rate_limit:install/, error.message)

    assert_raises(SolidQueue::RateLimitState::PendingMigrations) { ActiveJob.perform_all_later([ AddToBufferJob.new("b"), LimitedJob.new("c") ]) }
    assert_equal 0, SolidQueue::Job.count
  end

  test "enqueueing a coalesced limited job raises the same error, single or bulk" do
    [ CoalescedLimitedJob, CollectingLimitedJob ].each do |job_class|
      assert_raises(SolidQueue::RateLimitState::PendingMigrations) { job_class.perform_later("a") }
      assert_raises(SolidQueue::RateLimitState::PendingMigrations) { ActiveJob.perform_all_later([ job_class.new("b") ]) }
      assert_raises(SolidQueue::RateLimitState::PendingMigrations) { ActiveJob.perform_all_later([ AddToBufferJob.new("c"), job_class.new("d") ]) }
    end

    assert_equal 0, SolidQueue::Job.count
  end

  test "normal jobs enqueue and run as before" do
    AddToBufferJob.perform_later("hey")
    ActiveJob.perform_all_later([ AddToBufferJob.new("ho") ])

    perform_ready_jobs

    assert_equal %w[ hey ho ], JobBuffer.values.sort
  end

  test "a limited job that reaches a worker waits a minute, and the error is logged once" do
    log = StringIO.new
    travel_to Time.utc(2026, 1, 1, 12)
    2.times do |i|
      active_job = AddToBufferJob.perform_later(i)
      job = SolidQueue::Job.find(active_job.provider_job_id)
      job.update_columns(class_name: LimitedJob.name, arguments: job.arguments.merge("job_class" => LimitedJob.name))
    end

    SolidQueue.with(logger: ActiveSupport::Logger.new(log)) do
      process = SolidQueue::Process.register(kind: "Worker", pid: 42, name: "pending-migrations-worker")
      assert_empty SolidQueue::ReadyExecution.claim("*", 1, process.id)
      assert_empty SolidQueue::ReadyExecution.claim("*", 1, process.id)
    end

    assert_equal [ 1.minute.from_now ] * 2, SolidQueue::ScheduledExecution.pluck(:scheduled_at)
    assert_equal 1, log.string.scan("solid_queue:rate_limit:install").size
  ensure
    travel_back
  end

  test "perform_now and other adapters don't enforce the limit or need the schema" do
    3.times { |i| LimitedJob.perform_now(i) }
    LimitedJob.with(queue_adapter: :inline) { 3.times { |i| LimitedJob.perform_later(i + 3) } }

    assert_equal [ 0, 1, 2, 3, 4, 5 ], JobBuffer.values
  end

  private
    def migrate(direction)
      ActiveRecord::Migration.suppress_messages do
        SolidQueue::Record.connection_pool.with_connection do |connection|
          CreateSolidQueueRateLimits.new.exec_migration(connection, direction)
        end
      end

      SolidQueue::RateLimitState.instance_variable_set(:@migrated, nil)
      SolidQueue::ReadyExecution.instance_variable_set(:@pending_rate_limit_migrations_logged, nil)
      SolidQueue::Record.connection_pool.disconnect!
    end
end
