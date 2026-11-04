# frozen_string_literal: true

require "test_helper"
require "open3"

class ReloadingTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  # Reloading can't be turned on in this process, since it's fixed at boot.
  test "the patches survive a code reload" do
    output, status = Open3.capture2e({ "RAILS_ENV" => "test", "ENABLE_RELOADING" => "1", "TARGET_DB" => ENV["TARGET_DB"] }, RbConfig.ruby, "-e", <<~RUBY)
      require "#{Rails.root.join("config/environment")}"

      before = [ SolidQueue::ReadyExecution, ThrottledJob ]
      Rails.application.reloader.reload!
      raise "SolidQueue::ReadyExecution wasn't reloaded" if before.first.equal?(SolidQueue::ReadyExecution)
      raise "ThrottledJob wasn't reloaded" if before.last.equal?(ThrottledJob)

      jobs = 2.times.map { |i| ThrottledJob.perform_later(i) }
      process = SolidQueue::Process.register(kind: "Worker", pid: 42, name: "reloading-worker")
      claimed = SolidQueue::ReadyExecution.claim("*", 10, process.id)
      raise "ReadyExecution.claim lost its patch" unless claimed.map(&:job_id) == [ jobs.first.provider_job_id ]
      raise "The deferred job wasn't scheduled" unless SolidQueue::ScheduledExecution.pluck(:job_id) == [ jobs.last.provider_job_id ]

      SolidQueue::RateLimitState.define_singleton_method(:migrated?) { false }
      begin
        ThrottledJob.perform_later("pending")
        raise "Job.enqueue lost its patch"
      rescue SolidQueue::RateLimitState::PendingMigrations
      end

      SolidQueue::Job.destroy_all
      SolidQueue::Process.destroy_all
      SolidQueue::RateLimitState.delete_all
      puts "reloaded"
    RUBY

    assert status.success?, output
    assert_match(/reloaded/, output)
  end
end
