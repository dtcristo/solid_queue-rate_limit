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
      #
      # Claims that insert a new budget's row at once can deadlock on MySQL, and a
      # deadlock in the first pass would stop the worker, so that pass runs once more.
      module Claiming
        MAX_CLAIM_PASSES = 5

        private
          def select_and_lock(queue_relation, process_id, limit)
            return super unless RateLimit.enforced? && !connection_pool.with_connection(&:transaction_open?)

            claimed = []
            retried = false

            MAX_CLAIM_PASSES.times do |pass|
              begin
                claimed += super(queue_relation, process_id, limit - claimed.size)
              rescue ActiveRecord::Deadlocked
                # Whatever earlier passes claimed has been committed
                break if pass.positive?
                raise if retried

                retried = true
                retry
              end

              break unless claimed.size < limit && rate_limit_deferred_in_pass?
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

      # A claim that defers jobs inserts scheduled executions while it holds ready ones,
      # and the dispatcher inserts ready executions while it holds scheduled ones, so on
      # MySQL the two can deadlock. The dispatcher doesn't rescue errors, and would stop,
      # so a deadlocked batch runs once more.
      module Dispatching
        def dispatch_next_batch(batch_size)
          return super unless RateLimit.enforced? && !connection_pool.with_connection(&:transaction_open?)

          retried = false

          begin
            super
          rescue ActiveRecord::Deadlocked
            raise if retried

            retried = true
            retry
          end
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
        SolidQueue::ScheduledExecution.singleton_class.prepend Dispatching
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
