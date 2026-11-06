# frozen_string_literal: true

require "test_helper"

# GCRA with T = per / (to - burst + 1) and τ = (burst - 1) × T, as the spec states it
class SolidQueue::RateLimitStateTest < ActiveSupport::TestCase
  setup do
    @now = Time.utc(2026, 1, 1, 12)
    @state = SolidQueue::RateLimitState.new(key: "MyJob", tat: @now)
  end

  test "a full budget admits the burst at once, then rejects" do
    assert_equal [ true, true, true, false ], Array.new(4) { @state.admit(1, 3, @now) }
    assert_equal @now + 3, @state.tat
  end

  test "after the burst, admissions are spaced by the interval" do
    3.times { @state.admit(1, 3, @now) }

    assert @state.admit(1, 3, @now + 1)
    assert_not @state.admit(1, 3, @now + 1)
    assert_not @state.admit(1, 3, @now + 1.999999)
    assert @state.admit(1, 3, @now + 2)
  end

  test "admits when tat is exactly now + τ" do
    @state.tat = @now + 2

    assert @state.admit(1, 3, @now)
    assert_equal @now + 3, @state.tat
  end

  test "a long idle budget recovers only to the burst" do
    @state.tat = @now - 1.hour

    assert_equal [ true, true, false ], Array.new(3) { @state.admit(1, 2, @now) }
  end

  test "a loosened limit clamps the debt of the old one" do
    @state.tat = @now + 1.hour

    assert_not @state.admit(1, 2, @now)
    assert_equal @now + 2, @state.tat
    assert_equal @now + 1, @state.defer(1, 2, @now)
  end

  test "rounds tat up to the microsecond" do
    @state.admit(Rational(1, 3), 1, @now)

    assert_equal @now + Rational(333_334, 1_000_000), @state.tat
  end

  test "fractional intervals never admit more than the rate" do
    admitted = (0..999).count { |ms| @state.admit(Rational(1, 3), 1, @now + Rational(ms, 1000)) }

    assert_equal 3, admitted
    assert @state.tat > @now + 1
  end

  test "a rejected job waits for the next free slot" do
    @state.admit(2, 1, @now)

    assert_equal @now + 2, @state.defer(2, 1, @now)
  end

  test "each rejected job gets the slot after the last one handed out" do
    @state.admit(2, 1, @now)

    assert_equal [ @now + 2, @now + 4, @now + 6 ], Array.new(3) { @state.defer(2, 1, @now) }
    assert_equal @now + 6, @state.deferred_until
  end

  test "slots ignore a deferred_until that has passed" do
    @state.admit(2, 1, @now)
    @state.deferred_until = @now - 1.minute

    assert_equal @now + 2, @state.defer(2, 1, @now)
  end

  test "slots start after the burst's spare capacity" do
    3.times { @state.admit(10, 3, @now) }

    assert_equal @now + 10, @state.defer(10, 3, @now)
  end

  test "slots never charge the budget" do
    @state.admit(2, 1, @now)
    @state.defer(2, 1, @now)

    assert_equal @now + 2, @state.tat
    assert @state.admit(2, 1, @now + 2)
  end

  test "a slot more than 5 minutes away rechecks in 5 minutes without taking it" do
    @state.admit(60, 1, @now)
    @state.deferred_until = @now + 4.minutes + 30.seconds

    assert_equal @now + 5.minutes, @state.defer(60, 1, @now)
    assert_equal @now + 4.minutes + 30.seconds, @state.deferred_until
  end

  test "a slot exactly 5 minutes away is taken" do
    @state.admit(60, 1, @now)
    @state.deferred_until = @now + 4.minutes

    assert_equal @now + 5.minutes, @state.defer(60, 1, @now)
    assert_equal @now + 5.minutes, @state.deferred_until
  end

  test "rounds slots up to the microsecond" do
    @state.admit(Rational(1, 3), 1, @now)

    assert_equal [ @now + Rational(333_334, 1_000_000), @now + Rational(666_668, 1_000_000) ], Array.new(2) { @state.defer(Rational(1, 3), 1, @now) }
  end
end
