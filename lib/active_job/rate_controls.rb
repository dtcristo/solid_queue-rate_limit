# frozen_string_literal: true

module ActiveJob
  # Limits how fast workers start a job class's jobs. See #limits_rate.
  module RateControls
    extend ActiveSupport::Concern

    DEFAULT_RATE_LIMIT_GROUP = ->(*) { self.class.name }
    MIN_RATE_LIMIT_INTERVAL = 0.001

    # Stored in the job's serialized Active Job data, which Active Job ignores when running the job
    RATE_LIMIT_KEY = "solid_queue_rate_limit_key"

    included do
      class_attribute :rate_limit_to, instance_accessor: false
      class_attribute :rate_limit_per, instance_accessor: false
      class_attribute :rate_limit_burst, instance_accessor: false
      class_attribute :rate_limit_key, instance_accessor: false
      class_attribute :rate_limit_group, default: DEFAULT_RATE_LIMIT_GROUP, instance_accessor: false
    end

    module ClassMethods
      # Admits this class's jobs at worker claim no faster than +to+ per +per+,
      # using GCRA. A job over the limit waits as a scheduled job, without taking
      # a worker thread or a retry, and is checked again when it's dispatched.
      #
      #   class SyncStripeJob < ApplicationJob
      #     limits_rate to: 100, per: 1.minute, burst: 10, key: :global
      #   end
      #
      # ==== Options
      #
      # * +:to+ - Required. A positive integer, how many jobs a +per+ admits.
      # * +:per+ - Required. A positive duration. Admissions are spaced <tt>per / to</tt>
      #   apart, which has to be at least 1 ms.
      # * +:key+ - Required. A String or Symbol literal, or a Proc that receives the job's
      #   arguments, as in +limits_concurrency+. Each value gets a budget of its own. A
      #   +nil+ or +false+ key turns the limit off, as it turns off +limits_concurrency+.
      # * +:burst+ - How many jobs a fully recovered budget admits at once. Defaults to 1.
      # * +:group+ - Shares the budget with every class that names the same group. Takes
      #   the same values as +:key+. Defaults to the class's name.
      #
      #   class SyncStripeCustomerJob < ApplicationJob
      #     limits_rate to: 100, per: 1.minute, group: "Stripe", key: ->(account) { account }
      #   end
      #
      # A subclass inherits the limit, key and group. Without a group it has its own
      # budget, and it can redeclare the limit. An invalid option raises +ArgumentError+.
      # +perform_now+ and other adapters don't enforce it, and never compute the key.
      def limits_rate(to:, per:, key:, burst: 1, group: DEFAULT_RATE_LIMIT_GROUP, **options)
        if options.key?(:name)
          raise ArgumentError, "`name` isn't supported yet. Follow https://github.com/dtcristo/solid_queue-rate_limit/issues/14 for multiple limits"
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

        ensure_rate_limit_compatible_with_concurrency_controls(rate_limited: key)

        @rate_limit_declared = SolidQueue::RateLimit.declared = true
        self.rate_limit_to = to
        self.rate_limit_per = per
        self.rate_limit_burst = burst
        self.rate_limit_key = key
        self.rate_limit_group = group
      end

      def rate_limited?
        rate_limit_key ? true : false
      end

      # The seconds between admissions
      def rate_limit_interval # :nodoc:
        rate_limit_per.to_r / rate_limit_to
      end

      def limits_concurrency(on_conflict: :block, **) # :nodoc:
        ensure_rate_limit_compatible_with_concurrency_controls(discards_on_conflict: on_conflict == :discard)
        super
      end

      private
        # A deferred job that comes back to a taken slot would be discarded, dropping work already accepted
        def ensure_rate_limit_compatible_with_concurrency_controls(rate_limited: rate_limited?, discards_on_conflict: concurrency_key.present? && concurrency_on_conflict == :discard)
          if rate_limited && discards_on_conflict
            raise ArgumentError, "`limits_rate` can't be combined with `limits_concurrency(on_conflict: :discard)`"
          end
        end
    end

    # The key is computed once, when Solid Queue enqueues the job, and stored with it.
    # A claim reads it without deserializing arguments, and a retry keeps it. Every
    # path into Solid Queue serializes the job before writing it, including ones other
    # gems add, so this is where a limited job finds out the schema is missing.
    def serialize # :nodoc:
      if self.class.rate_limited? && self.class.queue_adapter_name == "solid_queue"
        raise SolidQueue::RateLimitState::PendingMigrations unless SolidQueue::RateLimitState.migrated?

        @rate_limit_key ||= rate_limit_key.presence&.tap { |key| ensure_rate_limit_key_fits(key) }
      end

      @rate_limit_key ? super.merge(RATE_LIMIT_KEY => @rate_limit_key) : super
    end

    def deserialize(job_data) # :nodoc:
      super
      @rate_limit_key = job_data[RATE_LIMIT_KEY]
    end

    def rate_limit_key # :nodoc:
      if self.class.rate_limited?
        param = compute_concurrency_parameter(self.class.rate_limit_key)

        case param
        when ActiveRecord::Base
          [ rate_limit_group, param.class.name, param.id ]
        else
          [ rate_limit_group, param ]
        end.compact.join("/")
      end
    end

    private
      # Raised here rather than at claim, where it would fail every claim that took the job
      def ensure_rate_limit_key_fits(key)
        if (limit = SolidQueue::RateLimitState.columns_hash["key"].limit) && key.length > limit
          raise ActiveRecord::ValueTooLong, "#{self.class.name}'s rate limit key is #{key.length} characters long, and solid_queue_rate_limits.key allows #{limit}"
        end
      end

      def rate_limit_group
        compute_concurrency_parameter(self.class.rate_limit_group)
      end
  end
end
