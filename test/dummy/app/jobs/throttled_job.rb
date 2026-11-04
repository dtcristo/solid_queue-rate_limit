class ThrottledJob < ApplicationJob
  limits_rate to: 1, per: 1.minute

  def perform(arg)
    JobBuffer.add(arg)
  end
end
