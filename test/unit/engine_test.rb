# frozen_string_literal: true

require "test_helper"

class EngineTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  test "loads into the app" do
    assert_includes Rails.application.railties.map(&:class), SolidQueue::RateLimit::Engine
  end

  test "workers claim and perform jobs as Solid Queue does" do
    AddToBufferJob.perform_later("claimed")

    perform_ready_jobs

    assert_equal [ "claimed" ], JobBuffer.values
    assert_no_unfinished_jobs
  end
end
