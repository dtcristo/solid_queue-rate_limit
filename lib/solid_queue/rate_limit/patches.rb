# frozen_string_literal: true

# Every place this gem reaches into Solid Queue. All of it depends on private
# details of the version pinned in the gemspec.
module SolidQueue
  module RateLimit
    module Patches # :nodoc: all
      def self.apply
      end
    end
  end
end
