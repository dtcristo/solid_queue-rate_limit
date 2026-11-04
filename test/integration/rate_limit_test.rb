# frozen_string_literal: true

require "test_helper"

# End to end, with a supervisor running forked workers and a dispatcher
class RateLimitTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  class TenASecondJob < ApplicationJob
    limits_rate to: 10, per: 1.second, burst: 3

    def perform(value)
      JobResult.create!(queue_name: "default", status: "limited", value: value)
    end
  end

  class UnlimitedJob < ApplicationJob
    def perform(value)
      JobResult.create!(queue_name: "default", status: "unlimited", value: value)
    end
  end

  setup do
    wait_for_registered_processes(0, timeout: 5.seconds)
    destroy_records

    # Forked workers inherit this subscriber, and append each claim to a file we read
    @claims_path = Rails.root.join("tmp/rate_limit_claims_#{SecureRandom.hex(4)}.log").to_s
    claims_path = @claims_path
    @subscriber = ActiveSupport::Notifications.subscribe("claim.solid_queue") do |_name, start, _finish, _id, payload|
      File.open(claims_path, "a") { |file| payload[:claimed_job_ids].each { |job_id| file.puts "#{job_id} #{start.to_f}" } }
    end

    worker = { queues: "*", polling_interval: 0.1, processes: 2, threads: 3 }
    dispatcher = { polling_interval: 0.1, batch_size: 200 }
    @pid = run_supervisor_as_fork(workers: [ worker ], dispatchers: [ dispatcher ])
    wait_for_registered_processes(4, timeout: 3.seconds) # 2 workers + dispatcher + supervisor
  end

  teardown do
    ActiveSupport::Notifications.unsubscribe(@subscriber)
    terminate_process(@pid) if @pid && process_exists?(@pid)
    wait_for_registered_processes(0, timeout: 5.seconds)
    destroy_records
    FileUtils.rm_f(@claims_path)
  end

  test "workers claim limited jobs at the rate, and every job runs" do
    limited = Array.new(30) { |i| TenASecondJob.new(i) }
    ActiveJob.perform_all_later(limited + Array.new(20) { |i| UnlimitedJob.new(i) })

    wait_for_jobs_to_finish_for(10.seconds)
    assert_no_unfinished_jobs

    limited_ids = limited.map(&:provider_job_id).to_set
    claims = File.readlines(@claims_path).map { |line| line.split.then { |job_id, time| [ Integer(job_id), Float(time) ] } }
    times = claims.select { |job_id, _| limited_ids.include?(job_id) }.map(&:last).sort

    assert_equal 30, times.size
    assert_operator times.each_cons(4).map { |first, *, last| last - first }.min, :>=, 0.1 - 0.02, "after a burst of 3, the 4th claim waits an interval"
    assert_operator times.map { |t0| times.count { |t| t >= t0 && t < t0 + 1 } }.max, :<=, 3 + 10
    assert_operator times.last - times.first, :<=, (30 - 3) * 0.1 + 1.5

    assert_equal (0...30).to_a, JobResult.where(status: "limited").pluck(:value).map(&:to_i).sort
    assert_equal 20, JobResult.where(status: "unlimited").count
  end
end
