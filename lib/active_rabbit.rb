# frozen_string_literal: true

require_relative "active_rabbit/client"

# Load Rails integration
if defined?(Rails)
  begin
    require_relative "active_rabbit/client/railtie"
  rescue => e
    warn "[ActiveRabbit] Rails integration failed: #{e.message}" if Rails.env&.development?
    warn "[ActiveRabbit] Backtrace: #{e.backtrace.first(5).join(', ')}" if Rails.env&.development?
  end
end
