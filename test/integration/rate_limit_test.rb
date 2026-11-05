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

  # Records the time each admission was charged at, in the thread that charged it.
  # A claim starts some time after that, so timing claims would misjudge the rate.
  module RecordAdmissions
    def admit(interval, burst, now)
      super.tap { |admitted| (Thread.current[:rate_limit_test_admissions] ||= []) << now.to_r if admitted && key == TenASecondJob.name }
    end
  end

  SolidQueue::RateLimitState.prepend RecordAdmissions

  setup do
    wait_for_registered_processes(0, timeout: 5.seconds)
    destroy_records

    # Forked workers inherit this subscriber, and append each admission that commits
    # to a file we read
    @admissions_path = Rails.root.join("tmp/rate_limit_admissions_#{SecureRandom.hex(4)}.log").to_s
    admissions_path = @admissions_path
    @subscriber = ActiveSupport::Notifications.subscribe("transaction.active_record") do |*, payload|
      if (admissions = Thread.current[:rate_limit_test_admissions])&.any?
        File.open(admissions_path, "a") { |file| file.puts(admissions) } if payload[:outcome] == :commit
        admissions.clear
      end
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
    FileUtils.rm_f(@admissions_path)
  end

  test "workers claim limited jobs at the rate, and every job runs" do
    limited = Array.new(30) { |i| TenASecondJob.new(i) }
    ActiveJob.perform_all_later(limited + Array.new(20) { |i| UnlimitedJob.new(i) })

    wait_for_jobs_to_finish_for(10.seconds)
    assert_no_unfinished_jobs

    times = File.readlines(@admissions_path).map { |line| Rational(line) }.sort

    assert_equal 30, times.size
    assert_operator times.each_cons(4).map { |first, *, last| last - first }.min, :>=, Rational(1, 10), "after a burst of 3, the 4th admission waits an interval"
    assert_operator times.map { |t0| times.count { |t| t >= t0 && t < t0 + 1 } }.max, :<=, 3 + 10
    assert_operator times.last - times.first, :<=, (30 - 3) * 0.1 + 1.5

    assert_equal (0...30).to_a, JobResult.where(status: "limited").pluck(:value).map(&:to_i).sort
    assert_equal 20, JobResult.where(status: "unlimited").count
  end
end
