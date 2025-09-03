# frozen_string_literal: true

require_relative "active_rabbit/client"

# Require Rails integration if Rails is available
require_relative "active_rabbit/client/railtie" if defined?(Rails)
