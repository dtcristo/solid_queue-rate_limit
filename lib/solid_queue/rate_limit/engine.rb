# frozen_string_literal: true

module SolidQueue
  module RateLimit
    class Engine < ::Rails::Engine # :nodoc:
      initializer "solid_queue.rate_limit.active_job", after: "solid_queue.active_job.extensions" do
        ActiveSupport.on_load :active_job do
          include ActiveJob::RateControls
        end
      end

      # Solid Queue's models are reloadable, so a reload needs the patches again
      config.to_prepare { Patches.apply }
    end
  end
end
