#!/usr/bin/env ruby
# Test script to verify ActiveRabbit is working with your API

require 'net/http'
require 'json'
require 'time'

puts "🚀 Testing ActiveRabbit Integration with Your API"
puts "=" * 50

# Your configuration
API_KEY = "9b3344ba8775e8ab11fd47e04534ae81e938180a23de603e60b5ec4346652f06"
PROJECT_ID = "1"
API_URL = "http://localhost:3000"

puts "Configuration:"
puts "- API URL: #{API_URL}"
puts "- Project ID: #{PROJECT_ID}"
puts "- API Key: #{API_KEY[0..10]}..."

# Test 1: Check API connectivity
puts "\n📡 Testing API connectivity..."
begin
  uri = URI("#{API_URL}/api/v1/test/connection")
  http = Net::HTTP.new(uri.host, uri.port)

  request = Net::HTTP::Post.new(uri.path)
  request['Content-Type'] = 'application/json'
  request['X-Project-Token'] = API_KEY
  request['X-Project-ID'] = PROJECT_ID
  request.body = JSON.generate({
    gem_version: "0.3.1",
    timestamp: Time.now.iso8601
  })

  response = http.request(request)

  if response.code.to_i == 200
    puts "✅ API connection successful!"
    puts "   Response: #{response.body}"
  else
    puts "❌ API connection failed with status: #{response.code}"
    puts "   Response: #{response.body}"
  end
rescue => e
  puts "❌ API connection error: #{e.message}"
end

# Test 2: Send a test exception
puts "\n🐛 Testing exception tracking..."
begin
  uri = URI("#{API_URL}/api/v1/events/errors")
  http = Net::HTTP.new(uri.host, uri.port)

  request = Net::HTTP::Post.new(uri.path)
  request['Content-Type'] = 'application/json'
  request['X-Project-Token'] = API_KEY
  request['X-Project-ID'] = PROJECT_ID

  exception_data = {
    type: "TestError",
    message: "This is a test exception from ActiveRabbit gem",
    backtrace: [
      { filename: "test_script.rb", lineno: 42, method: "test_method", line: "test_script.rb:42:in `test_method'" }
    ],
    fingerprint: "test_fingerprint_123",
    timestamp: Time.now.iso8601(3),
    environment: "development",
    context: {
      request: {
        method: "GET",
        path: "/test",
        user_agent: "ActiveRabbit-Test/1.0"
      }
    },
    event_type: "error"
  }

  request.body = JSON.generate(exception_data)

  response = http.request(request)

  if response.code.to_i == 200
    puts "✅ Exception tracking successful!"
    puts "   Response: #{response.body}"
  else
    puts "❌ Exception tracking failed with status: #{response.code}"
    puts "   Response: #{response.body}"
  end
rescue => e
  puts "❌ Exception tracking error: #{e.message}"
end

# Test 3: Send test performance data
puts "\n⚡ Testing performance tracking..."
begin
  uri = URI("#{API_URL}/api/v1/events/performance")
  http = Net::HTTP.new(uri.host, uri.port)

  request = Net::HTTP::Post.new(uri.path)
  request['Content-Type'] = 'application/json'
  request['X-Project-Token'] = API_KEY
  request['X-Project-ID'] = PROJECT_ID

  performance_data = {
    name: "controller.action",
    duration_ms: 150.5,
    metadata: {
      controller: "TestController",
      action: "index",
      method: "GET",
      path: "/test"
    },
    timestamp: Time.now.iso8601(3),
    environment: "development",
    event_type: "performance"
  }

  request.body = JSON.generate(performance_data)

  response = http.request(request)

  if response.code.to_i == 200
    puts "✅ Performance tracking successful!"
    puts "   Response: #{response.body}"
  else
    puts "❌ Performance tracking failed with status: #{response.code}"
    puts "   Response: #{response.body}"
  end
rescue => e
  puts "❌ Performance tracking error: #{e.message}"
end

# Test 4: Make requests to your app to trigger ActiveRabbit
puts "\n🌐 Testing requests to your app (port 3003)..."

test_urls = [
  "http://localhost:3003/",
  "http://localhost:3003/nonexistent-page",  # Should trigger 404
  "http://localhost:3003/test-error"         # Might trigger an error
]

test_urls.each do |url|
  puts "\nTesting: #{url}"
  begin
    uri = URI(url)
    http = Net::HTTP.new(uri.host, uri.port)
    http.read_timeout = 5

    request = Net::HTTP::Get.new(uri.path)
    request['User-Agent'] = 'ActiveRabbit-Test/1.0'

    response = http.request(request)
    puts "  Status: #{response.code} #{response.message}"

    if response.code.to_i >= 400
      puts "  ⚠️  This should trigger ActiveRabbit error tracking!"
    end

  rescue => e
    puts "  Error: #{e.message}"
    puts "  ⚠️  This should trigger ActiveRabbit exception tracking!"
  end
end

puts "\n" + "=" * 50
puts "🎉 Test completed!"
puts "Check your ActiveRabbit dashboard at #{API_URL} for tracked events."
puts "=" * 50
