#!/usr/bin/env ruby
# frozen_string_literal: true

# Test script to verify Rails integration works properly
# This script can be run in a Rails console to test the ActiveRabbit integration

require 'bundler/setup'
require_relative '../lib/active_rabbit'

puts "🚀 Testing ActiveRabbit Rails Integration"
puts "=" * 50

# Test 1: Check if Rails integration is loaded
if defined?(Rails)
  puts "✅ Rails detected"

  if defined?(ActiveRabbit::Client::Railtie)
    puts "✅ ActiveRabbit::Client::Railtie loaded"
  else
    puts "❌ ActiveRabbit::Client::Railtie NOT loaded"
  end
else
  puts "❌ Rails not detected - creating mock Rails environment"

  # Create a minimal Rails-like environment for testing
  require 'pathname'
  require 'logger'

  # Mock Rails::Railtie first
  module Rails
    class Railtie
      def self.config
        @config ||= OpenStruct.new
      end

      def self.initializer(name, options = {}, &block)
        puts "  📋 Initializer registered: #{name}"
      end
    end

    def self.env
      "test"
    end

    def self.logger
      @logger ||= Logger.new(STDOUT)
    end

    def self.root
      Pathname.new(Dir.pwd)
    end

    def self.version
      "7.0.0"
    end
  end

  # Mock ActiveSupport::OrderedOptions
  require 'ostruct'
  module ActiveSupport
    class OrderedOptions < OpenStruct; end

    module Notifications
      def self.subscribe(name, &block)
        puts "  📡 Subscribed to notification: #{name}"
      end
    end
  end

  # Mock ActionDispatch
  module ActionDispatch
    class ShowExceptions; end
    class Request
      def initialize(env); end
    end
  end

  # Load the railtie now that Rails is defined
  require_relative '../lib/active_rabbit/client/railtie'
  puts "✅ Railtie loaded with mock Rails environment"
end

# Test 2: Check configuration
puts "\n📋 Testing Configuration"
puts "-" * 30

ActiveRabbit::Client.configure do |config|
  config.api_key = "test_api_key_123"
  config.api_url = "https://api.test.com"
  config.environment = "test"
  config.project_id = "test_project"
end

if ActiveRabbit::Client.configured?
  puts "✅ ActiveRabbit configured successfully"
else
  puts "❌ ActiveRabbit configuration failed"
end

# Test 3: Test middleware classes exist
puts "\n🔧 Testing Middleware"
puts "-" * 30

if defined?(ActiveRabbit::Client::RequestContextMiddleware)
  puts "✅ RequestContextMiddleware defined"
else
  puts "❌ RequestContextMiddleware NOT defined"
end

if defined?(ActiveRabbit::Client::ExceptionMiddleware)
  puts "✅ ExceptionMiddleware defined"
else
  puts "❌ ExceptionMiddleware NOT defined"
end

# Test 4: Test exception tracking
puts "\n🐛 Testing Exception Tracking"
puts "-" * 30

begin
  # Create a test exception
  test_exception = StandardError.new("Test exception for ActiveRabbit")
  test_exception.set_backtrace([
    "/app/controllers/test_controller.rb:10:in `index'",
    "/app/config/routes.rb:5:in `call'"
  ])

  # Track the exception
  ActiveRabbit::Client.track_exception(
    test_exception,
    context: {
      request: {
        method: "GET",
        path: "/test",
        controller: "TestController",
        action: "index"
      }
    }
  )

  puts "✅ Exception tracking works"
rescue => e
  puts "❌ Exception tracking failed: #{e.message}"
  puts "   #{e.backtrace.first}"
end

# Test 5: Test event tracking
puts "\n📊 Testing Event Tracking"
puts "-" * 30

begin
  ActiveRabbit::Client.track_event(
    "test_event",
    {
      user_id: "test_user_123",
      action: "button_click",
      page: "homepage"
    }
  )

  puts "✅ Event tracking works"
rescue => e
  puts "❌ Event tracking failed: #{e.message}"
end

# Test 6: Test performance tracking
puts "\n⚡ Testing Performance Tracking"
puts "-" * 30

begin
  ActiveRabbit::Client.track_performance(
    "controller.action",
    250.5,
    metadata: {
      controller: "TestController",
      action: "index",
      db_queries: 3
    }
  )

  puts "✅ Performance tracking works"
rescue => e
  puts "❌ Performance tracking failed: #{e.message}"
end

# Test 7: Test connection (this will fail without real API but should not crash)
puts "\n🌐 Testing API Connection"
puts "-" * 30

connection_result = ActiveRabbit::Client.test_connection
if connection_result[:success]
  puts "✅ API connection successful"
else
  puts "⚠️  API connection failed (expected in test): #{connection_result[:error]}"
end

# Test 8: Test flush
puts "\n💾 Testing Flush"
puts "-" * 30

begin
  ActiveRabbit::Client.flush
  puts "✅ Flush works"
rescue => e
  puts "❌ Flush failed: #{e.message}"
end

puts "\n" + "=" * 50
puts "🎉 Rails integration test completed!"
puts "   Check the output above for any failures."
puts "=" * 50
