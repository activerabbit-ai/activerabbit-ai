#!/usr/bin/env ruby
# Script to trigger errors in your app and test ActiveRabbit

require 'net/http'

puts "🐛 Triggering errors in your app to test ActiveRabbit..."
puts "=" * 50

test_urls = [
  "http://localhost:3003/",
  "http://localhost:3003/trigger-error",  # This might cause an exception
  "http://localhost:3003/users/999999",   # Non-existent user
  "http://localhost:3003/admin/secret",   # Unauthorized access
  "http://localhost:3003/api/v1/test",    # API endpoint that might not exist
]

test_urls.each_with_index do |url, index|
  puts "\n#{index + 1}. Testing: #{url}"

  begin
    uri = URI(url)
    http = Net::HTTP.new(uri.host, uri.port)
    http.read_timeout = 10

    request = Net::HTTP::Get.new(uri.path)
    request['User-Agent'] = 'ActiveRabbit-ErrorTest/1.0'

    response = http.request(request)

    puts "   Status: #{response.code} #{response.message}"

    case response.code.to_i
    when 200..299
      puts "   ✅ Success - Normal request"
    when 404
      puts "   ⚠️  404 Not Found - This should be tracked by ActiveRabbit!"
    when 500..599
      puts "   🚨 Server Error - This should definitely be tracked by ActiveRabbit!"
    else
      puts "   ⚠️  #{response.code} Error - This should be tracked by ActiveRabbit!"
    end

  rescue => e
    puts "   💥 Exception: #{e.class}: #{e.message}"
    puts "   🚨 This network error should be tracked by ActiveRabbit!"
  end

  # Small delay between requests
  sleep(0.5)
end

puts "\n" + "=" * 50
puts "✅ Test completed!"
puts ""
puts "Now check your ActiveRabbit logs and dashboard:"
puts "1. Check ActiveRabbit API logs at http://localhost:3000"
puts "2. Look for error entries in your ActiveRabbit database"
puts "3. Check your app logs on port 3003 for ActiveRabbit activity"
puts ""
puts "If ActiveRabbit is working, you should see:"
puts "- Exception tracking logs in your app"
puts "- HTTP requests to localhost:3000/api/v1/events/errors"
puts "- Error entries in your ActiveRabbit dashboard"
puts "=" * 50
