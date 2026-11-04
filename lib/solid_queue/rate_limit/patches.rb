# frozen_string_literal: true

# Every place this gem reaches into Solid Queue. All of it depends on private
# details of the version pinned in the gemspec.
module SolidQueue
  module RateLimit
    module Patches # :nodoc: all
      # Admission runs in lock_candidates, inside the claim's transaction and after
      # select_candidates has locked the ready executions with SKIP LOCKED.
      #
      # A pass that deferred jobs leaves threads idle that could run jobs behind them,
      # so the claim looks again, each time in a transaction of its own.
      module Claiming
        MAX_CLAIM_PASSES = 5

        private
          def select_and_lock(queue_relation, process_id, limit)
            return super unless RateLimit.enforced? && !connection_pool.with_connection(&:transaction_open?)

            claimed = []

            MAX_CLAIM_PASSES.times do |pass|
              claimed += super(queue_relation, process_id, limit - claimed.size)
              break unless claimed.size < limit && rate_limit_deferred_in_pass?
            rescue ActiveRecord::Deadlocked
              # Whatever earlier passes claimed has been committed
              raise if pass.zero?
              break
            end

            claimed
          end

          def lock_candidates(executions, process_id)
            ActiveSupport::IsolatedExecutionState[:solid_queue_rate_limit_deferred] = false
            return super unless RateLimit.enforced? && executions.any?

            deferred = defer_rate_limited(executions)
            return super if deferred.empty?

            ActiveSupport::IsolatedExecutionState[:solid_queue_rate_limit_deferred] = true

            super(executions - deferred, process_id).tap do
              where(id: deferred.map(&:id)).delete_all
            end
          end

          def rate_limit_deferred_in_pass?
            ActiveSupport::IsolatedExecutionState.delete(:solid_queue_rate_limit_deferred)
          end
      end

      # Prepended rather than added to the adapter, because RecurringTask calls
      # Job.enqueue directly. A limited job can't be admitted without the schema,
      # so it's better to find out when it's enqueued.
      module Enqueuing
        def enqueue_all(active_jobs)
          ensure_rate_limitable if active_jobs.any? { |active_job| active_job.class.rate_limited? }
          super
        end

        def enqueue(active_job, **)
          ensure_rate_limitable if active_job.class.rate_limited?
          super
        end

        private
          def ensure_rate_limitable
            raise RateLimitState::PendingMigrations unless RateLimitState.migrated?
          end
      end

      def self.apply
        SolidQueue::Job.singleton_class.prepend Enqueuing
        SolidQueue::ReadyExecution.include SolidQueue::ReadyExecution::RateLimited
        SolidQueue::ReadyExecution.singleton_class.prepend Claiming
      end
    end
  end
end

class SolidQueue::LogSubscriber
  # A backlog can defer jobs on every claim, so above debug it shouldn't build a line for each
  subscribe_log_level :defer_rate_limited, :debug

  def defer_rate_limited(event) # :nodoc:
    debug formatted_event(event, action: "Defer rate-limited jobs", **event.payload.slice(:class_name, :keys, :job_ids, :size))
  end
end
