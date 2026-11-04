# frozen_string_literal: true

require "test_helper"

class SolidQueue::RateLimitDeclarationTest < ActiveSupport::TestCase
  test "declares a rate with a default burst of 1" do
    job_class = job { limits_rate to: 100, per: 1.minute }

    assert job_class.rate_limited?
    assert_equal 100, job_class.rate_limit_to
    assert_equal 1.minute, job_class.rate_limit_per
    assert_equal 1, job_class.rate_limit_burst
  end

  test "declares a burst" do
    assert_equal 10, job { limits_rate to: 100, per: 1.minute, burst: 10 }.rate_limit_burst
  end

  test "a job class without a rate isn't limited" do
    assert_not job { }.rate_limited?
    assert_not ActiveJob::Base.rate_limited?
    assert_nil job { }.rate_limit_to
  end

  test "to must be a positive integer" do
    [ 0, -1, 1.5, "10", nil ].each do |to|
      error = assert_raises(ArgumentError) { job { limits_rate to: to, per: 1.minute } }
      assert_equal "`to` must be a positive integer", error.message
    end
  end

  test "per must be a positive duration" do
    [ 0.seconds, -1.minute, 60, nil ].each do |per|
      error = assert_raises(ArgumentError) { job { limits_rate to: 1, per: per } }
      assert_equal "`per` must be a positive duration", error.message
    end
  end

  test "burst must be a positive integer" do
    [ 0, -1, 2.5, nil ].each do |burst|
      error = assert_raises(ArgumentError) { job { limits_rate to: 1, per: 1.minute, burst: burst } }
      assert_equal "`burst` must be a positive integer", error.message
    end
  end

  test "spacing below 1 ms raises" do
    error = assert_raises(ArgumentError) { job { limits_rate to: 1_001, per: 1.second } }
    assert_match(/at least 1 ms apart/, error.message)

    assert_equal 1_000, job { limits_rate to: 1_000, per: 1.second }.rate_limit_to
  end

  test "planned options raise with a link to the roadmap" do
    [ { key: ->(account) { account } }, { group: "Stripe" }, { name: :account } ].each do |option|
      error = assert_raises(ArgumentError) { job { limits_rate to: 1, per: 1.minute, **option } }
      assert_match(/`#{option.keys.first}` isn't supported yet/, error.message)
      assert_match(%r{https://github.com/dtcristo/solid_queue-rate_limit/issues/3}, error.message)
    end
  end

  test "unknown keywords raise" do
    error = assert_raises(ArgumentError) { job { limits_rate to: 1, per: 1.minute, duration: 1.minute } }
    assert_match(/unknown keyword: :duration/, error.message)
  end

  test "a second limits_rate in the same class raises" do
    error = assert_raises(ArgumentError) do
      job do
        limits_rate to: 1, per: 1.minute
        limits_rate to: 2, per: 1.minute
      end
    end

    assert_match(/already declares `limits_rate`/, error.message)
  end

  test "a subclass inherits the limit" do
    parent = job { limits_rate to: 5, per: 1.minute, burst: 2 }
    child = Class.new(parent)

    assert child.rate_limited?
    assert_equal [ 5, 1.minute, 2 ], [ child.rate_limit_to, child.rate_limit_per, child.rate_limit_burst ]
  end

  test "a subclass can redeclare the limit without changing its parent's" do
    parent = job { limits_rate to: 5, per: 1.minute }
    child = Class.new(parent) { limits_rate to: 10, per: 1.second, burst: 3 }

    assert_equal [ 10, 1.second, 3 ], [ child.rate_limit_to, child.rate_limit_per, child.rate_limit_burst ]
    assert_equal [ 5, 1.minute, 1 ], [ parent.rate_limit_to, parent.rate_limit_per, parent.rate_limit_burst ]
  end

  test "limits_rate after limits_concurrency raises" do
    error = assert_raises(ArgumentError) do
      job do
        limits_concurrency key: ->(*) { "all" }
        limits_rate to: 1, per: 1.minute
      end
    end

    assert_match(/can't be combined with `limits_concurrency`/, error.message)
    assert_match(%r{https://github.com/dtcristo/solid_queue-rate_limit/issues/2}, error.message)
  end

  test "limits_concurrency after limits_rate raises" do
    error = assert_raises(ArgumentError) do
      job do
        limits_rate to: 1, per: 1.minute
        limits_concurrency key: ->(*) { "all" }
      end
    end

    assert_match(%r{https://github.com/dtcristo/solid_queue-rate_limit/issues/2}, error.message)
  end

  test "the conflict raises through inheritance, in both orders" do
    concurrency_limited = job { limits_concurrency key: ->(*) { "all" } }
    rate_limited = job { limits_rate to: 1, per: 1.minute }

    assert_raises(ArgumentError) { Class.new(concurrency_limited) { limits_rate to: 1, per: 1.minute } }
    assert_raises(ArgumentError) { Class.new(rate_limited) { limits_concurrency key: ->(*) { "all" } } }
  end

  private
    def job(&block)
      Class.new(ApplicationJob, &block)
    end
end
