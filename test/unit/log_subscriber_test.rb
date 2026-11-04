# frozen_string_literal: true

require "test_helper"
require "active_support/log_subscriber/test_helper"

class LogSubscriberTest < ActiveSupport::TestCase
  include ActiveSupport::LogSubscriber::TestHelper

  teardown { ActiveSupport::LogSubscriber.log_subscribers.clear }

  # The helper sets a nil logger on teardown, and forked supervisors in later tests need one
  def set_logger(logger)
    @previous_logger ||= SolidQueue.logger
    SolidQueue.logger = logger || @previous_logger
  end

  test "defer rate-limited jobs" do
    attach_log_subscriber
    instrument "defer_rate_limited.solid_queue", class_name: "SyncStripeJob", keys: [ "Stripe/1" ], job_ids: [ 1, 2 ], size: 2

    assert_equal 1, @logger.logged(:debug).size
    assert_match(%r{SolidQueue-[\d.]+ Defer rate-limited jobs \(\d+\.\d+ms\)  class_name: "SyncStripeJob", keys: \["Stripe/1"\], job_ids: \[1, 2\], size: 2}, @logger.logged(:debug).last)
  end

  test "a deferral line isn't built above debug" do
    subscriber = attach_log_subscriber
    @logger.level = Logger::INFO

    assert subscriber.silenced?("defer_rate_limited.solid_queue")
  end

  private
    def attach_log_subscriber
      SolidQueue::LogSubscriber.new.tap { |subscriber| SolidQueue::LogSubscriber.attach_to :solid_queue, subscriber }
    end

    def instrument(...)
      ActiveSupport::Notifications.instrument(...)
      wait
    end
end
