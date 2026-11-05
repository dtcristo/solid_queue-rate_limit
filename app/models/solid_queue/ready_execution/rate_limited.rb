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
          job_classes = jobs.values.map(&:class_name).uniq.index_with { |class_name| rate_limited_job_class(class_name) }.compact

          limited = executions.select { |execution| (job = jobs[execution.job_id]) && job_classes[job.class_name] }
          return [] if limited.empty?

          keys = rate_limit_keys(limited, jobs, job_classes)

          next_checks = if RateLimitState.migrated?
            check_rate_limits(keys, jobs, job_classes)
          else
            log_pending_rate_limit_migrations
            limited.to_h { |execution| [ execution, 1.minute.from_now ] }
          end

          schedule_rate_limited(next_checks, jobs, keys)
          release_concurrency_locks(next_checks.keys.map(&:job_id).select { |job_id| jobs[job_id].concurrency_key })
          next_checks.keys
        end

        private
          # Locks every limit the candidates need, in key order, then charges them in queue
          # order, each with its own class's settings. Returns when each rejected candidate
          # should look again. The time is read once the locks are held, so claims that
          # share a limit see it move on.
          def check_rate_limits(keys, jobs, job_classes)
            states = RateLimitState.lock_all(keys.values.uniq)
            now = Time.current

            next_checks = keys.keys.each_with_object({}) do |execution, deferred|
              job_class = job_classes[jobs[execution.job_id].class_name]
              state = states[keys[execution]]

              unless state.admit(job_class.rate_limit_interval, job_class.rate_limit_burst, now)
                deferred[execution] = state.defer(job_class.rate_limit_interval, job_class.rate_limit_burst, now)
              end
            end

            states.each_value { |state| state.save! if state.changed? }
            next_checks
          end

          # Returns each candidate's key. Only a class that declares key: or group: stores
          # one with its jobs, so only theirs are read. Otherwise the key is the class's name,
          # which a job enqueued under an alias, or before its class declared a key, shares.
          def rate_limit_keys(executions, jobs, job_classes)
            keyed = executions.select { |execution| job_classes[jobs[execution.job_id].class_name].rate_limit_keyed? }
            stored = keyed.any? ? Job.where(id: keyed.map(&:job_id)).pluck(:id, :arguments).to_h { |id, arguments| [ id, arguments[ActiveJob::RateControls::RATE_LIMIT_KEY] ] } : {}

            executions.index_with { |execution| stored[execution.job_id] || job_classes[jobs[execution.job_id].class_name].name }
          end

          def schedule_rate_limited(next_checks, jobs, keys)
            if next_checks.any?
              ScheduledExecution.insert_all(next_checks.map do |execution, scheduled_at|
                jobs[execution.job_id].slice(:queue_name, :priority).merge(job_id: execution.job_id, scheduled_at: scheduled_at)
              end)

              next_checks.keys.group_by { |execution| jobs[execution.job_id].class_name }.each do |class_name, deferred|
                SolidQueue.instrument(:defer_rate_limited, class_name: class_name, keys: keys.values_at(*deferred).uniq, job_ids: deferred.map(&:job_id), size: deferred.size)
              end
            end
          end

          # A deferred job gives its semaphore back while it waits, so the semaphore can't expire
          # and let a second job with its key run. It takes one again when it's dispatched.
          # Going through them by concurrency key, as dispatch_all_one_by_one does, makes
          # claims that release the same semaphores take them in the same order.
          def release_concurrency_locks(job_ids)
            if job_ids.any?
              Job.where(id: job_ids).sort_by { |job| [ job.concurrency_key, job.id ] }.each(&:unblock_next_blocked_job)
            end
          end

          # A class that can't be loaded fails its jobs when they run, as without the gem
          def rate_limited_job_class(class_name)
            job_class = class_name.constantize
            job_class if job_class.is_a?(Class) && job_class < ActiveJob::Base && job_class.rate_limited?
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
