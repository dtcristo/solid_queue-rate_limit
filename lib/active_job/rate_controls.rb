# frozen_string_literal: true

module ActiveJob
  # Limits how fast workers start a job class's jobs. See #limits_rate.
  module RateControls
    extend ActiveSupport::Concern

    MIN_RATE_LIMIT_INTERVAL = 0.001

    included do
      class_attribute :rate_limit_to, instance_accessor: false
      class_attribute :rate_limit_per, instance_accessor: false
      class_attribute :rate_limit_burst, instance_accessor: false
    end

    module ClassMethods
      # Admits this class's jobs at worker claim no faster than +to+ per +per+,
      # using GCRA. A job over the limit waits as a scheduled job, without taking
      # a worker thread or a retry, and is checked again when it's dispatched.
      #
      #   class SyncStripeJob < ApplicationJob
      #     limits_rate to: 100, per: 1.minute, burst: 10
      #   end
      #
      # ==== Options
      #
      # * +:to+ - Required. A positive integer, how many jobs a +per+ admits.
      # * +:per+ - Required. A positive duration. Admissions are spaced <tt>per / to</tt>
      #   apart, which has to be at least 1 ms.
      # * +:burst+ - How many jobs a fully recovered budget admits at once. Defaults to 1.
      #
      # A subclass has its own budget, and can redeclare the limit. An invalid option
      # raises +ArgumentError+. +perform_now+ and other adapters don't enforce it.
      def limits_rate(to:, per:, burst: 1, **options)
        if (planned = options.keys & %i[ key group name ]).any?
          raise ArgumentError, "`#{planned.first}` isn't supported yet. Follow https://github.com/dtcristo/solid_queue-rate_limit/issues/3 for shared, keyed and multiple limits"
        elsif options.any?
          raise ArgumentError, "unknown keyword#{"s" if options.many?}: #{options.keys.map(&:inspect).join(", ")}"
        end

        unless to.is_a?(Integer) && to.positive?
          raise ArgumentError, "`to` must be a positive integer"
        end

        unless per.is_a?(ActiveSupport::Duration) && per.positive?
          raise ArgumentError, "`per` must be a positive duration"
        end

        unless burst.is_a?(Integer) && burst.positive?
          raise ArgumentError, "`burst` must be a positive integer"
        end

        if per.to_r / to < MIN_RATE_LIMIT_INTERVAL
          raise ArgumentError, "`limits_rate to: #{to}, per: #{per.inspect}` would admit jobs less than 1 ms apart, and they have to be at least 1 ms apart"
        end

        if @rate_limit_declared
          raise ArgumentError, "#{name || "This class"} already declares `limits_rate`"
        end

        ensure_rate_limit_compatible_with_concurrency_controls(rate_limited: true)

        @rate_limit_declared = SolidQueue::RateLimit.declared = true
        self.rate_limit_to = to
        self.rate_limit_per = per
        self.rate_limit_burst = burst
      end

      def rate_limited?
        rate_limit_to.present?
      end

      # The seconds between admissions
      def rate_limit_interval # :nodoc:
        rate_limit_per.to_r / rate_limit_to
      end

      def limits_concurrency(**) # :nodoc:
        ensure_rate_limit_compatible_with_concurrency_controls(concurrency_limited: true)
        super
      end

      private
        def ensure_rate_limit_compatible_with_concurrency_controls(rate_limited: rate_limited?, concurrency_limited: concurrency_key.present?)
          if rate_limited && concurrency_limited
            raise ArgumentError, "`limits_rate` can't be combined with `limits_concurrency` yet. Follow https://github.com/dtcristo/solid_queue-rate_limit/issues/2"
          end
        end
    end
  end
end
