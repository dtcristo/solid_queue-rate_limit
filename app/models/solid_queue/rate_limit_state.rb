# frozen_string_literal: true

module SolidQueue
  # The GCRA state of one limit. +tat+ is the theoretical arrival time: the budget
  # is full when it's in the past, and each admission moves it on by the interval.
  # +deferred_until+ is the latest slot handed to a waiting job. It's only a hint
  # for staggering their next checks, and never charges the budget.
  class RateLimitState < Record # :nodoc:
    self.table_name = "solid_queue_rate_limits"

    # The furthest a waiting job is sent ahead, so a job that's cancelled or a limit
    # that's loosened can't strand capacity for longer than this.
    MAX_DEFERRAL = 5.minutes

    # Enqueuing a job that uses +limits_rate+ before the gem's migration has run.
    class PendingMigrations < StandardError
      def initialize(message = "The rate limiting schema hasn't been installed yet. Run `bin/rails generate solid_queue:rate_limit:install` to copy the migration to your application, and then `bin/rails db:migrate` to run it")
        super
      end
    end

    class << self
      # Until the app has run the gem's migration everything else works as before.
      def migrated?
        @migrated ||= table_exists?
      end
    end

    # Charges one admission and returns true, or returns false if the budget is spent.
    # +interval+ is the seconds between admissions, and +burst+ how many a full
    # budget admits at once.
    def admit(interval, burst, now)
      clamp(interval, burst, now)

      if tat <= now + spare(interval, burst)
        self.tat = ceil_usec([ tat, now ].max + interval)
        true
      else
        false
      end
    end

    # When a job the budget rejected should look again: the next free slot after
    # the ones already handed out, or MAX_DEFERRAL from now if that's further.
    def defer(interval, burst, now)
      clamp(interval, burst, now)

      slot = ceil_usec([ tat - spare(interval, burst), deferred_until&.+(interval) ].compact.max)

      if slot <= now + MAX_DEFERRAL
        self.deferred_until = slot
      else
        now + MAX_DEFERRAL
      end
    end

    private
      # A loosened limit applies at once, instead of after the old one's debt
      def clamp(interval, burst, now)
        self.tat = [ tat, ceil_usec(now + burst * interval) ].min
      end

      def spare(interval, burst)
        (burst - 1) * interval
      end

      # Rounding down could erase a little of the debt on every admission
      def ceil_usec(time)
        time.ceil(6)
      end
  end
end
