# frozen_string_literal: true

# Every place this gem reaches into Solid Queue. All of it depends on private
# details of the version pinned in the gemspec.
module SolidQueue
  module RateLimit
    module Patches # :nodoc: all
      # Admission runs in lock_candidates, inside the claim's transaction and after
      # select_candidates has locked the ready executions with SKIP LOCKED.
      module Claiming
        private
          def lock_candidates(executions, process_id)
            return super unless RateLimit.enforced? && executions.any?

            deferred = defer_rate_limited(executions)
            return super if deferred.empty?

            super(executions - deferred, process_id).tap do
              where(id: deferred.map(&:id)).delete_all
            end
          end
      end

      def self.apply
        SolidQueue::ReadyExecution.include SolidQueue::ReadyExecution::RateLimited
        SolidQueue::ReadyExecution.singleton_class.prepend Claiming
      end
    end
  end
end
