# frozen_string_literal: true

require_relative "active_rabbit/client"
require_relative "active_rabbit/routing/not_found_app"

# Load Rails integration
require_relative "active_rabbit/client/railtie" if defined?(Rails)
