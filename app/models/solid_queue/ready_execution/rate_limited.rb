# frozen_string_literal: true

module SolidQueue
  class ReadyExecution
    module RateLimited # :nodoc: all
      extend ActiveSupport::Concern

      class_methods do
        # Moves the candidates whose class is over its rate to scheduled executions,
        # leaving their jobs' own scheduled_at as it is, and returns them. Called inside
        # the claim's transaction, after the candidates have been locked.
        def defer_rate_limited(executions)
          jobs = Job.where(id: executions.map(&:job_id)).select(:id, :class_name, :queue_name, :priority, :concurrency_key).index_by(&:id)
          job_classes = jobs.values.map(&:class_name).uniq.filter_map { |class_name| rate_limited_job_class(class_name) }.index_by(&:name)

          # A job with a concurrency key holds its semaphore, so it can't wait here
          limited = executions.select { |execution| jobs[execution.job_id].concurrency_key.nil? && job_classes[jobs[execution.job_id].class_name] }
          return [] if limited.empty?

          next_checks = if RateLimitState.migrated?
            check_rate_limits(limited, jobs, job_classes)
          else
            log_pending_rate_limit_migrations
            limited.to_h { |execution| [ execution, 1.minute.from_now ] }
          end

          schedule_rate_limited(next_checks, jobs)
          next_checks.keys
        end

        private
          # Locks every limit the candidates need, in key order, then charges them in queue
          # order. Returns when each rejected candidate should look again. The time is
          # read once the locks are held, so claims that share a limit see it move on.
          def check_rate_limits(executions, jobs, job_classes)
            states = RateLimitState.lock_all(executions.map { |execution| jobs[execution.job_id].class_name }.uniq)
            now = Time.current

            next_checks = executions.each_with_object({}) do |execution, deferred|
              job_class = job_classes[jobs[execution.job_id].class_name]
              state = states[job_class.name]

              unless state.admit(job_class.rate_limit_interval, job_class.rate_limit_burst, now)
                deferred[execution] = state.defer(job_class.rate_limit_interval, job_class.rate_limit_burst, now)
              end
            end

            states.each_value { |state| state.save! if state.changed? }
            next_checks
          end

          def schedule_rate_limited(next_checks, jobs)
            if next_checks.any?
              ScheduledExecution.insert_all(next_checks.map do |execution, scheduled_at|
                jobs[execution.job_id].slice(:queue_name, :priority).merge(job_id: execution.job_id, scheduled_at: scheduled_at)
              end)

              next_checks.keys.group_by { |execution| jobs[execution.job_id].class_name }.each do |class_name, deferred|
                SolidQueue.instrument(:defer_rate_limited, class_name: class_name, job_ids: deferred.map(&:job_id), size: deferred.size)
              end
            end
          end

          # A class that can't be loaded fails its jobs when they run, as without the gem
          def rate_limited_job_class(class_name)
            job_class = class_name.constantize
            job_class if job_class.try(:rate_limited?)
          rescue StandardError, ScriptError
            nil
          end

          def log_pending_rate_limit_migrations
            @pending_rate_limit_migrations_logged ||= SolidQueue.logger&.error("Rate-limited jobs are waiting for the rate limiting schema. #{RateLimitState::PendingMigrations.new.message}") || true
          end
      end
    end
  end
end
