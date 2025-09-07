#!/usr/bin/env ruby
# Simple test script for the new Net::HTTP implementation

$LOAD_PATH.unshift(File.expand_path('../lib', __FILE__))

require 'active_rabbit/client/version'
require 'active_rabbit/client/configuration'
require 'active_rabbit/client/http_client'

puts "🚀 Testing ActiveRabbit Net::HTTP Implementation"
puts "=" * 50

# Test configuration
config = ActiveRabbit::Client::Configuration.new
config.api_key = "test_api_key_123"
config.api_url = "https://httpbin.org"  # Use httpbin for testing
config.timeout = 10
config.open_timeout = 5
config.retry_count = 2
config.retry_delay = 1

puts "✅ Configuration created"

# Test HTTP client
begin
  http_client = ActiveRabbit::Client::HttpClient.new(config)
  puts "✅ HTTP Client created"

  # Test a simple GET-like request (httpbin.org/post accepts POST)
  puts "\n📡 Testing HTTP request..."

  response = http_client.send(:make_request, :post, "post", {
    test: "data",
    gem_version: ActiveRabbit::Client::VERSION,
    timestamp: Time.now.to_i
  })

  puts "✅ HTTP request successful!"
  puts "Response keys: #{response.keys.join(', ')}" if response.is_a?(Hash)

rescue => e
  puts "❌ HTTP request failed: #{e.message}"
  puts "   #{e.class}: #{e.backtrace.first}"
end

puts "\n" + "=" * 50
puts "🎉 Net::HTTP implementation test completed!"
