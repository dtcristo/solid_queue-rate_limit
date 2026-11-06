# frozen_string_literal: true

require "test_helper"

class SolidQueue::RateLimitDeclarationTest < ActiveSupport::TestCase
  test "declares a rate with a default burst of 1" do
    job_class = job { limits_rate to: 100, per: 1.minute, key: :global }

    assert job_class.rate_limited?
    assert_equal 100, job_class.rate_limit_to
    assert_equal 1.minute, job_class.rate_limit_per
    assert_equal 1, job_class.rate_limit_burst
  end

  test "declares a burst" do
    assert_equal 10, job { limits_rate to: 100, per: 1.minute, burst: 10, key: :global }.rate_limit_burst
  end

  test "a job class without a rate isn't limited" do
    assert_not job { }.rate_limited?
    assert_not ActiveJob::Base.rate_limited?
    assert_nil job { }.rate_limit_to
  end

  test "to must be a positive integer" do
    [ 0, -1, 1.5, "10", nil ].each do |to|
      error = assert_raises(ArgumentError) { job { limits_rate to: to, per: 1.minute, key: :global } }
      assert_equal "`to` must be a positive integer", error.message
    end
  end

  test "per must be a positive duration" do
    [ 0.seconds, -1.minute, 60, nil ].each do |per|
      error = assert_raises(ArgumentError) { job { limits_rate to: 1, per: per, key: :global } }
      assert_equal "`per` must be a positive duration", error.message
    end
  end

  test "burst must be a positive integer" do
    [ 0, -1, 2.5, nil ].each do |burst|
      error = assert_raises(ArgumentError) { job { limits_rate to: 1, per: 1.minute, burst: burst, key: :global } }
      assert_equal "`burst` must be a positive integer", error.message
    end
  end

  test "burst can't be more than to" do
    error = assert_raises(ArgumentError) { job { limits_rate to: 2, per: 1.minute, burst: 3, key: :global } }
    assert_equal "`burst` can't be more than `to`", error.message

    assert_equal 2, job { limits_rate to: 2, per: 1.minute, burst: 2, key: :global }.rate_limit_burst
  end

  test "spacing below 1 ms raises" do
    error = assert_raises(ArgumentError) { job { limits_rate to: 1_001, per: 1.second, key: :global } }
    assert_match(/at least 1 ms apart/, error.message)

    assert_equal 1_000, job { limits_rate to: 1_000, per: 1.second, key: :global }.rate_limit_to
  end

  test "spacing below 1 ms raises, counting the burst" do
    error = assert_raises(ArgumentError) { job { limits_rate to: 1_002, per: 1.second, burst: 2, key: :global } }
    assert_match(/at least 1 ms apart/, error.message)

    assert_equal 1_001, job { limits_rate to: 1_001, per: 1.second, burst: 2, key: :global }.rate_limit_to
  end

  test "declares a key and a group, as limits_concurrency takes them" do
    key = ->(account) { account }
    job_class = job { limits_rate to: 1, per: 1.minute, key: key, group: "Stripe" }

    assert_equal key, job_class.rate_limit_key
    assert_equal "Stripe", job_class.rate_limit_group
    assert_equal ActiveJob::RateControls::DEFAULT_RATE_LIMIT_GROUP, job { limits_rate to: 1, per: 1.minute, key: :global }.rate_limit_group
  end

  test "key is required" do
    error = assert_raises(ArgumentError) { job { limits_rate to: 1, per: 1.minute } }
    assert_match(/missing keyword: :key/, error.message)
  end

  test "a nil or false key declaration disables the limit, like limits_concurrency" do
    [ nil, false ].each do |key|
      job_class = job do
        limits_rate to: 1, per: 1.minute, key: key
        limits_concurrency key: key, on_conflict: :discard
      end

      assert_not job_class.rate_limited?
      assert_nil job_class.new.rate_limit_key
      assert_not job_class.new.concurrency_limited?
    end
  end

  test "name raises with a link to multiple limits" do
    error = assert_raises(ArgumentError) { job { limits_rate to: 1, per: 1.minute, name: :account, key: :global } }

    assert_match(/`name` isn't supported yet/, error.message)
    assert_match(%r{https://github.com/dtcristo/solid_queue-rate_limit/issues/14}, error.message)
  end

  test "unknown keywords raise" do
    error = assert_raises(ArgumentError) { job { limits_rate to: 1, per: 1.minute, duration: 1.minute, key: :global } }
    assert_match(/unknown keyword: :duration/, error.message)
  end

  test "a second limits_rate in the same class raises" do
    error = assert_raises(ArgumentError) do
      job do
        limits_rate to: 1, per: 1.minute, key: :global
        limits_rate to: 2, per: 1.minute, key: :global
      end
    end

    assert_match(/already declares `limits_rate`/, error.message)
  end

  test "a subclass inherits the limit" do
    parent = job { limits_rate to: 5, per: 1.minute, burst: 2, key: :global }
    child = Class.new(parent)

    assert child.rate_limited?
    assert_equal [ 5, 1.minute, 2 ], [ child.rate_limit_to, child.rate_limit_per, child.rate_limit_burst ]
  end

  test "a subclass inherits the key and the group, and redeclaring the limit drops the group" do
    parent = job { limits_rate to: 5, per: 1.minute, key: :account, group: "Stripe" }
    child = Class.new(parent) { limits_rate to: 5, per: 1.minute, key: :global }

    assert_equal [ :account, "Stripe" ], [ Class.new(parent).rate_limit_key, Class.new(parent).rate_limit_group ]
    assert_equal [ :global, ActiveJob::RateControls::DEFAULT_RATE_LIMIT_GROUP ], [ child.rate_limit_key, child.rate_limit_group ]
  end

  test "a subclass redeclares the limit with a key, and a nil key turns it off" do
    parent = job { limits_rate to: 5, per: 1.minute, key: :global }

    assert_raises(ArgumentError) { Class.new(parent) { limits_rate to: 10, per: 1.minute } }
    assert_not Class.new(parent) { limits_rate to: 5, per: 1.minute, key: nil }.rate_limited?
    assert parent.rate_limited?
  end

  test "a subclass can redeclare the limit without changing its parent's" do
    parent = job { limits_rate to: 5, per: 1.minute, key: :global }
    child = Class.new(parent) { limits_rate to: 10, per: 1.second, burst: 3, key: :global }

    assert_equal [ 10, 1.second, 3 ], [ child.rate_limit_to, child.rate_limit_per, child.rate_limit_burst ]
    assert_equal [ 5, 1.minute, 1 ], [ parent.rate_limit_to, parent.rate_limit_per, parent.rate_limit_burst ]
  end

  test "limits_rate and limits_concurrency combine in either order" do
    [ proc { limits_concurrency key: ->(*) { "all" }; limits_rate to: 1, per: 1.minute, key: :global },
      proc { limits_rate to: 1, per: 1.minute, key: :global; limits_concurrency key: ->(*) { "all" } } ].each do |declarations|
      job_class = job(&declarations)

      assert job_class.rate_limited?
      assert job_class.concurrency_key.present?
    end
  end

  test "limits_rate and limits_concurrency combine through inheritance" do
    concurrency_limited = job { limits_concurrency key: ->(*) { "all" } }
    rate_limited = job { limits_rate to: 1, per: 1.minute, key: :global }

    [ Class.new(concurrency_limited) { limits_rate to: 1, per: 1.minute, key: :global }, Class.new(rate_limited) { limits_concurrency key: ->(*) { "all" } } ].each do |job_class|
      assert job_class.rate_limited?
      assert job_class.concurrency_key.present?
    end
  end

  test "limits_rate with limits_concurrency that discards on conflict raises, in either order" do
    [ proc { limits_concurrency key: ->(*) { "all" }, on_conflict: :discard; limits_rate to: 1, per: 1.minute, key: :global },
      proc { limits_rate to: 1, per: 1.minute, key: :global; limits_concurrency key: ->(*) { "all" }, on_conflict: :discard } ].each do |declarations|
      error = assert_raises(ArgumentError) { job(&declarations) }

      assert_equal "`limits_rate` can't be combined with `limits_concurrency(on_conflict: :discard)`", error.message
    end
  end

  test "limits_rate with limits_concurrency that discards on conflict raises through inheritance" do
    discarding = job { limits_concurrency key: ->(*) { "all" }, on_conflict: :discard }
    rate_limited = job { limits_rate to: 1, per: 1.minute, key: :global }

    assert_raises(ArgumentError) { Class.new(discarding) { limits_rate to: 1, per: 1.minute, key: :global } }
    assert_raises(ArgumentError) { Class.new(rate_limited) { limits_concurrency key: ->(*) { "all" }, on_conflict: :discard } }
  end

  private
    def job(&block)
      Class.new(ApplicationJob, &block)
    end
end
