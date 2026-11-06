class ThrottledJob < ApplicationJob
  limits_rate to: 1, per: 1.minute, key: :global

  def perform(arg)
    JobBuffer.add(arg)
  end
end
