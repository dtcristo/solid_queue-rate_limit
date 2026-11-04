# frozen_string_literal: true

module SolidQueue
  module RateLimit
    class Engine < ::Rails::Engine # :nodoc:
      # Solid Queue's models are reloadable, so a reload needs the patches again
      config.to_prepare { Patches.apply }
    end
  end
end
