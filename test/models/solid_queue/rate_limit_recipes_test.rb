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

  private
    # Returns when each job was claimed, in seconds from the start, sorted. With a block,
    # pairs each time with what the block returns for the claim's job IDs.
    def run_dispatcher_and_worker(duration, poll: 1)
      claims = []

      (duration / poll).to_i.succ.times do |tick|
        travel_to @start + tick * poll, with_usec: true
        SolidQueue::ScheduledExecution.dispatch_next_batch(500)

        travel CLAIM_DELAYS[tick % CLAIM_DELAYS.size], with_usec: true
        job_ids = SolidQueue::ReadyExecution.claim("*", 500, @process.id).map(&:job_id)
        labels = block_given? ? yield(job_ids) : job_ids
        claims.concat(labels.map { |label| block_given? ? [ Time.current - @start, label ] : Time.current - @start })
        SolidQueue::Job.where(id: job_ids).destroy_all
      end

      claims.sort
    end

    def most_in_any(seconds, times)
      times.map { |t0| times.count { |t| t >= t0 && t < t0 + seconds } }.max
    end
end
