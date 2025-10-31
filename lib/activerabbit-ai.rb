# frozen_string_literal: true

# Compatibility loader for Bundler and Rails autoloading
# because gem names cannot map "-" to "_" automatically.
# This ensures `require "activerabbit-ai"` loads the real code.

require_relative "active_rabbit"
