# frozen_string_literal: true

require "solid_queue"

require "active_job/rate_controls"
require "solid_queue/rate_limit/version"
require "solid_queue/rate_limit/patches"
require "solid_queue/rate_limit/engine"

module SolidQueue
  module RateLimit
    # Set once any job class declares limits_rate
    mattr_accessor :declared, default: false

    # Without eager loading, a job's class may not be loaded until its job is claimed
    def self.enforced? # :nodoc:
      declared || !Rails.application.config.eager_load
    end
  end
end
