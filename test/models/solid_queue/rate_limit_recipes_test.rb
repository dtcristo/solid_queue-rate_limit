# frozen_string_literal: true

require "test_helper"

# What the README's recipes and burst rule promise, with a dispatcher and a worker
# in simulated time. The worker claims a little after each dispatcher poll, by an
# amount that varies as it does with a real worker polling every 0.1 seconds.
class SolidQueue::RateLimitRecipesTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  class QuotaJob < ApplicationJob
    limits_rate to: 90, per: 1.minute, burst: 10

    def perform; end
  end

  class SpacedJob < ApplicationJob
    limits_rate to: 1, per: 5.seconds

    def perform; end
  end

  class FullRateJob < ApplicationJob
    limits_rate to: 5, per: 1.second, burst: 6

    def perform; end
  end

  class FastPollJob < ApplicationJob
    limits_rate to: 5, per: 1.second, burst: 2

    def perform; end
  end

  class OneBurstJob < ApplicationJob
    limits_rate to: 1, per: 1.second

    def perform; end
  end

  class TwoBurstJob < ApplicationJob
    limits_rate to: 1, per: 1.second, burst: 2

    def perform; end
  end

  # 100 × (0.1 + 0.1) / 1 = 20, and 11 only covers the dispatcher's poll
  class HundredBurstTwentyJob < ApplicationJob
    limits_rate to: 100, per: 1.second, burst: 20

    def perform; end
  end

  class HundredBurstElevenJob < ApplicationJob
    limits_rate to: 100, per: 1.second, burst: 11

    def perform; end
  end

  class PerShopJob < ApplicationJob
    limits_rate to: 2, per: 1.second, burst: 3, key: ->(shop) { shop }

    def perform(shop); end
  end

  class StripeCustomerJob < ApplicationJob
    limits_rate to: 90, per: 1.minute, burst: 10, group: "RecipesStripe"

    def perform(account); end
  end

  class StripeRefundJob < ApplicationJob
    limits_rate to: 90, per: 1.minute, burst: 10, group: "RecipesStripe"

    def perform(charge); end
  end

  class ConnectAccountJob < ApplicationJob
    limits_rate to: 25, per: 1.second, burst: 28, group: "RecipesStripeConnect", key: ->(account) { account }

    def perform(account); end
  end

  class ConnectTransferJob < ApplicationJob
    limits_rate to: 25, per: 1.second, burst: 28, group: "RecipesStripeConnect", key: ->(account, _amount) { account }

    def perform(account, amount); end
  end

  class StripeAccountSyncJob < ApplicationJob
    limits_concurrency key: ->(account) { account }
    limits_rate to: 100, per: 1.minute, burst: 10, group: "RecipesStripeSync"

    def perform(account); end
  end

  class PushInventoryJob < ApplicationJob
    coalesce key: ->(shop, _sku) { shop }, on_conflict: :collect, max_calls: 100
    limits_rate to: 8, per: 1.minute, burst: 2, key: ->(shop, _sku) { shop }

    def perform_calls(calls)
      JobBuffer.add([ calls.first.arguments.first, calls.map { |call| call.arguments.last } ])
    end
  end

  class SyncShopProductsJob < ApplicationJob
    coalesce key: ->(shop) { shop }
    limits_concurrency key: ->(shop) { shop }
    limits_rate to: 2, per: 1.second, burst: 3, group: "RecipesShopify"

    def perform(shop)
      JobBuffer.add(shop)
    end
  end

  CLAIM_DELAYS = [ 0.08, 0.02, 0.05 ]

  setup do
    @start = Time.utc(2026, 1, 1, 12)
    travel_to @start
    @process = SolidQueue::Process.register(kind: "Worker", pid: 42, name: "rate-limit-recipes-worker")
  end

  teardown do
    travel_back
  end

  test "every job class in the README loads with the options it shows" do
    classes = File.read(File.expand_path("../../../README.md", __dir__)).scan(/^class \w+ < ApplicationJob$.*?^end$/m)

    assert_operator classes.size, :>=, 4
    classes.each { |definition| assert Module.new.module_eval(definition) }
  end

  test "a quota per minute never claims more than to + burst in any minute, and keeps up with to" do
    300.times { QuotaJob.perform_later }

    claims = run_dispatcher_and_worker(3.minutes)

    assert_operator most_in_any(60, claims), :<=, 90 + 10
    assert_operator claims.size, :>=, 10 + 90 * 3 - 2
  end

  test "spaced jobs are never claimed less than the interval apart" do
    10.times { SpacedJob.perform_later }

    claims = run_dispatcher_and_worker(1.minute)

    assert_operator claims.size, :>=, 5
    assert_operator claims.each_cons(2).map { |first, second| second - first }.min, :>=, 5
  end

  test "with burst at the rule for the default poll, a backlog drains at the full rate" do
    60.times { FullRateJob.perform_later }

    claims = run_dispatcher_and_worker(15.seconds)

    assert_equal 60, claims.size
    assert_operator claims.max, :<=, (60 - 6) / 5.0 + 1.5
  end

  test "a faster dispatcher poll needs a smaller burst to drain a backlog at the full rate" do
    60.times { FastPollJob.perform_later }

    claims = run_dispatcher_and_worker(15.seconds, poll: 0.2)

    assert_equal 60, claims.size
    assert_operator claims.max, :<=, (60 - 2) / 5.0 + 1
  end

  test "with burst: 1 a backlog falls behind the rate, and burst: 2 keeps up" do
    30.times { OneBurstJob.perform_later }
    30.times { TwoBurstJob.perform_later }

    claims = run_dispatcher_and_worker(30.seconds) { |job_ids| SolidQueue::Job.where(id: job_ids).pluck(:class_name) }

    assert_operator claims.count { |_, class_name| class_name == OneBurstJob.name }, :<, 25
    assert_equal 30, claims.count { |_, class_name| class_name == TwoBurstJob.name }
  end

  test "at a high rate the burst also covers the worker's poll" do
    ActiveJob.perform_all_later(Array.new(500) { HundredBurstTwentyJob.new })
    fast = run_dispatcher_and_worker(5.seconds, poll: 0.1)
    destroy_records

    ActiveJob.perform_all_later(Array.new(500) { HundredBurstElevenJob.new })
    slow = run_dispatcher_and_worker(5.seconds, poll: 0.1)

    assert_equal 500, fast.size
    assert_operator fast.max, :<=, (500 - 20) / 100.0 + 0.3
    assert_operator slow.size, :<, 450
  end

  test "a key gives each account a budget of its own, and each drains at the full rate" do
    ActiveJob.perform_all_later(%w[ a b ].flat_map { |shop| Array.new(20) { PerShopJob.new(shop) } })

    claims = run_dispatcher_and_worker(15.seconds) { |job_ids| first_arguments(job_ids) }

    %w[ a b ].each do |shop|
      times = claims.filter_map { |time, label| time if label == shop }
      assert_equal 20, times.size
      assert_operator most_in_any(1, times), :<=, 3 + 2
      assert_operator times.max, :<=, (20 - 3) / 2.0 + 1.5
    end
  end

  test "classes in a group stay under one quota together" do
    ActiveJob.perform_all_later(Array.new(150) { |i| StripeCustomerJob.new(i) } + Array.new(150) { |i| StripeRefundJob.new(i) })

    claims = run_dispatcher_and_worker(3.minutes) { |job_ids| SolidQueue::Job.where(id: job_ids).pluck(:class_name) }
    times = claims.map(&:first)

    assert_operator most_in_any(60, times), :<=, 90 + 10
    assert_operator times.size, :>=, 10 + 90 * 3 - 2
    assert_equal [ StripeCustomerJob.name, StripeRefundJob.name ], claims.map(&:last).uniq.sort
  end

  test "classes in a group with a key share each account's budget, and each account drains at the full rate" do
    ActiveJob.perform_all_later(%w[ a b ].flat_map { |account| Array.new(40) { ConnectAccountJob.new(account) } + Array.new(40) { |i| ConnectTransferJob.new(account, i) } })

    claims = run_dispatcher_and_worker(5.seconds, poll: 1) { |job_ids| first_arguments(job_ids) }

    %w[ a b ].each do |account|
      times = claims.filter_map { |time, label| time if label == account }
      assert_equal 80, times.size
      assert_operator most_in_any(1, times), :<=, 28 + 25
      assert_operator times.max, :<=, (80 - 28) / 25.0 + 1.5
    end
  end

  test "per-account concurrency under a global rate runs one job per account at a time, and all of them stay under the rate" do
    ActiveJob.perform_all_later(%w[ a b c d e ].flat_map { |account| Array.new(30) { StripeAccountSyncJob.new(account) } })

    claims = run_dispatcher_and_worker(2.minutes) { |job_ids| first_arguments(job_ids) }
    times = claims.map(&:first)

    assert_equal 150, claims.size
    assert_operator most_in_any(60, times), :<=, 100 + 10
    assert_operator times.max, :<=, (150 - 10) * 0.6 + 1.5
    claims.group_by(&:first).each_value { |claimed_together| assert_equal claimed_together.map(&:last).uniq, claimed_together.map(&:last) }
  end

  test "batched calls reach the bulk API in requests of at most max_calls, under the quota for each shop" do
    calls = %w[ a b ].flat_map { |shop| Array.new(1000) { |sku| PushInventoryJob.new(shop, sku) } }
    ActiveJob.perform_all_later(calls)

    claims = run_dispatcher_and_worker(2.minutes) { |job_ids| first_arguments(job_ids) }
    requests = JobBuffer.values

    %w[ a b ].each do |shop|
      times = claims.filter_map { |time, label| time if label == shop }
      skus = requests.filter_map { |requested, batch| batch if requested == shop }

      assert_equal 10, times.size
      assert_operator most_in_any(60, times), :<=, 2 + 8
      assert skus.all? { |batch| batch.size <= 100 }
      assert_equal (0...1000).to_a, skus.flatten.sort
    end
  end

  test "collapsed calls run once for each shop, and all shops stay under the global rate" do
    ActiveJob.perform_all_later(%w[ a b c d e f g h ].flat_map { |shop| Array.new(20) { SyncShopProductsJob.new(shop) } })

    times = run_dispatcher_and_worker(10.seconds)

    assert_equal %w[ a b c d e f g h ], JobBuffer.values.sort
    assert_operator most_in_any(1, times), :<=, 3 + 2
    assert_operator times.max, :<=, (8 - 3) / 2.0 + 1.5
    assert_equal 0, SolidQueue::Semaphore.where("value < 1").count
  end

  test "the recurring task clears idle budgets and keeps the others" do
    task = SolidQueue::RecurringTask.from_configuration("clear_solid_queue_rate_limits", command: "SolidQueue::RateLimitState.clear_idle_in_batches(sleep_between_batches: 0.3)", schedule: "every hour at minute 27")
    ActiveJob.perform_all_later(%w[ a b ].map { |shop| PerShopJob.new(shop) })
    SolidQueue::ReadyExecution.claim("*", 500, @process.id)
    PerShopJob.perform_later("b")
    travel 2.seconds
    SolidQueue::ReadyExecution.claim("*", 500, @process.id)
    SolidQueue::RateLimitState.stubs(:sleep)

    assert task.valid?
    assert_difference -> { SolidQueue::RateLimitState.count }, -1 do
      SolidQueue::RecurringJob.perform_now(task.command)
    end
  end

  private
    def first_arguments(job_ids)
      SolidQueue::Job.where(id: job_ids).map { |job| job.arguments["arguments"].first }
    end

    # Returns when each job was claimed, in seconds from the start, sorted. With a block,
    # pairs each time with what the block returns for the claim's job IDs. Each job runs
    # as soon as it's claimed, so it gives back any concurrency slot it holds.
    def run_dispatcher_and_worker(duration, poll: 1)
      claims = []

      (duration / poll).to_i.succ.times do |tick|
        travel_to @start + tick * poll, with_usec: true
        SolidQueue::ScheduledExecution.dispatch_next_batch(500)

        travel CLAIM_DELAYS[tick % CLAIM_DELAYS.size], with_usec: true
        job_ids = SolidQueue::ReadyExecution.claim("*", 500, @process.id).map(&:job_id)
        labels = block_given? ? yield(job_ids) : job_ids
        claims.concat(labels.map { |label| block_given? ? [ Time.current - @start, label ] : Time.current - @start })
        SolidQueue::ClaimedExecution.where(job_id: job_ids).each(&:perform)
      end

      claims.sort
    end

    def most_in_any(seconds, times)
      times.map { |t0| times.count { |t| t >= t0 && t < t0 + seconds } }.max
    end
end
