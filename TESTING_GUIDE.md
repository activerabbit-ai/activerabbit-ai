# Testing ActiveRabbit Client with Rails Applications

This guide covers comprehensive testing strategies for the ActiveRabbit client gem in Rails applications before production deployment.

## 🧪 Testing Strategy Overview

### 1. **Unit Tests** - Test gem components in isolation
### 2. **Integration Tests** - Test gem integration with Rails
### 3. **End-to-End Tests** - Test complete error tracking flow
### 4. **Performance Tests** - Ensure minimal performance impact
### 5. **Production Simulation** - Test with realistic data volumes

## 🔧 Test Environment Setup

### Gemfile for Testing
```ruby
group :test do
  gem 'rspec-rails'
  gem 'webmock'
  gem 'vcr'
  gem 'factory_bot_rails'
  gem 'database_cleaner-active_record'
  gem 'timecop'
  gem 'rails-controller-testing'
end
```

### Test Configuration
```ruby
# spec/rails_helper.rb
require 'spec_helper'
require 'rspec/rails'
require 'webmock/rspec'
require 'vcr'

# Configure WebMock to stub HTTP requests
WebMock.disable_net_connect!(allow_localhost: true)

# Configure VCR for recording real API interactions
VCR.configure do |config|
  config.cassette_library_dir = "spec/vcr_cassettes"
  config.hook_into :webmock
  config.configure_rspec_metadata!
end

RSpec.configure do |config|
  config.use_transactional_fixtures = true
  config.infer_spec_type_from_file_location!
  config.filter_rails_from_backtrace!

  # Reset ActiveAgent configuration before each test
  config.before(:each) do
    ActiveAgent::Client.configuration = nil
    Thread.current[:active_agent_request_context] = nil
  end

  config.after(:each) do
    ActiveAgent::Client.configuration = nil
    Thread.current[:active_agent_request_context] = nil
  end
end
```

## 📝 Unit Tests for Gem Components

### Test Configuration
```ruby
# spec/active_agent/configuration_spec.rb
RSpec.describe ActiveAgent::Client::Configuration do
  describe "environment variable loading" do
    it "loads API key from environment" do
      allow(ENV).to receive(:[]).with("ACTIVE_AGENT_API_KEY").and_return("test-key")
      config = described_class.new
      expect(config.api_key).to eq("test-key")
    end
  end

  describe "validation" do
    it "validates required configuration" do
      config = described_class.new
      config.api_key = "test-key"
      config.api_url = "https://api.test.com"
      expect(config.valid?).to be true
    end
  end
end
```

### Test Exception Tracking
```ruby
# spec/active_agent/exception_tracker_spec.rb
RSpec.describe ActiveAgent::Client::ExceptionTracker do
  let(:configuration) { ActiveAgent::Client::Configuration.new }
  let(:http_client) { instance_double(ActiveAgent::Client::HttpClient) }
  let(:tracker) { described_class.new(configuration, http_client) }
  let(:exception) { StandardError.new("Test error") }

  before do
    configuration.api_key = "test-key"
    configuration.project_id = "test-project"
  end

  describe "#track_exception" do
    it "sends exception data to API" do
      expect(http_client).to receive(:post_exception).with(hash_including(
        type: "StandardError",
        message: "Test error"
      ))

      tracker.track_exception(
        exception: exception,
        context: { user_id: "123" }
      )
    end

    it "ignores filtered exceptions" do
      configuration.ignored_exceptions = ["StandardError"]

      expect(http_client).not_to receive(:post_exception)

      tracker.track_exception(exception: exception)
    end

    it "applies before_send callback" do
      configuration.before_send_exception = proc do |data|
        data[:custom_field] = "test_value"
        data
      end

      expect(http_client).to receive(:post_exception).with(
        hash_including(custom_field: "test_value")
      )

      tracker.track_exception(exception: exception)
    end
  end
end
```

### Test PII Scrubbing
```ruby
# spec/active_agent/pii_scrubber_spec.rb
RSpec.describe ActiveAgent::Client::PiiScrubber do
  let(:configuration) { ActiveAgent::Client::Configuration.new }
  let(:scrubber) { described_class.new(configuration) }

  describe "#scrub" do
    it "scrubs sensitive data" do
      data = {
        email: "user@example.com",
        password: "secret123",
        safe_field: "safe_value"
      }

      result = scrubber.scrub(data)

      expect(result[:email]).to eq("[FILTERED]")
      expect(result[:password]).to eq("[FILTERED]")
      expect(result[:safe_field]).to eq("safe_value")
    end
  end
end
```

## 🔗 Integration Tests with Rails

### Test Rails Middleware Integration
```ruby
# spec/integration/rails_integration_spec.rb
RSpec.describe "Rails Integration", type: :request do
  before do
    ActiveAgent::Client.configure do |config|
      config.api_key = "test-api-key"
      config.project_id = "test-project"
    end
  end

  describe "exception middleware" do
    it "captures unhandled exceptions" do
      # Stub the API call
      stub_request(:post, "https://api.activeagent.com/api/v1/exceptions")
        .to_return(status: 200, body: '{"status":"ok"}')

      # Create a route that raises an exception
      Rails.application.routes.draw do
        get '/test_error', to: proc { raise StandardError, "Test error" }
      end

      expect {
        get '/test_error'
      }.to raise_error(StandardError, "Test error")

      # Verify the API was called
      expect(WebMock).to have_requested(:post, "https://api.activeagent.com/api/v1/exceptions")
        .with(body: hash_including(
          type: "StandardError",
          message: "Test error"
        ))
    end
  end

  describe "performance monitoring" do
    it "tracks controller performance" do
      stub_request(:post, "https://api.activeagent.com/api/v1/performance")
        .to_return(status: 200, body: '{"status":"ok"}')

      get '/some_endpoint'

      expect(WebMock).to have_requested(:post, "https://api.activeagent.com/api/v1/performance")
    end
  end
end
```

### Test Controller Integration
```ruby
# spec/controllers/application_controller_spec.rb
RSpec.describe ApplicationController, type: :controller do
  controller do
    def index
      raise StandardError, "Controller error"
    end
  end

  before do
    ActiveAgent::Client.configure do |config|
      config.api_key = "test-key"
      config.project_id = "test-project"
    end

    stub_request(:post, /api\.activeagent\.com/)
      .to_return(status: 200, body: '{"status":"ok"}')
  end

  it "tracks exceptions with request context" do
    expect {
      get :index
    }.to raise_error(StandardError)

    expect(WebMock).to have_requested(:post, "https://api.activeagent.com/api/v1/exceptions")
      .with { |req|
        body = JSON.parse(req.body)
        body["context"]["request"]["method"] == "GET"
      }
  end
end
```

## 🎭 End-to-End Testing

### Test Complete Error Flow
```ruby
# spec/features/error_tracking_spec.rb
RSpec.describe "Error Tracking Flow", type: :feature do
  before do
    ActiveAgent::Client.configure do |config|
      config.api_key = "test-key"
      config.project_id = "test-project"
    end
  end

  scenario "user triggers an error and it gets tracked" do
    # Stub API calls
    exception_stub = stub_request(:post, "https://api.activeagent.com/api/v1/exceptions")
      .to_return(status: 200, body: '{"status":"ok"}')

    # Create a user and simulate an error condition
    user = create(:user)

    # Visit a page that will cause an error
    visit "/users/999999" # Non-existent user

    # Verify the exception was tracked
    expect(exception_stub).to have_been_requested.with { |req|
      body = JSON.parse(req.body)
      body["type"] == "ActiveRecord::RecordNotFound" &&
      body["context"]["request"]["path"] == "/users/999999"
    }
  end
end
```

### Test N+1 Query Detection
```ruby
# spec/features/n_plus_one_detection_spec.rb
RSpec.describe "N+1 Query Detection", type: :feature do
  before do
    ActiveAgent::Client.configure do |config|
      config.api_key = "test-key"
      config.enable_n_plus_one_detection = true
    end
  end

  scenario "detects N+1 queries" do
    event_stub = stub_request(:post, "https://api.activeagent.com/api/v1/events")
      .to_return(status: 200, body: '{"status":"ok"}')

    # Create test data that will cause N+1
    users = create_list(:user, 5)
    users.each { |user| create(:post, user: user) }

    # Visit page that triggers N+1 (without includes)
    visit "/users" # Assuming this lists users and their post counts

    # Verify N+1 detection was triggered
    expect(event_stub).to have_been_requested.with { |req|
      body = JSON.parse(req.body)
      body["name"] == "n_plus_one_detected"
    }
  end
end
```

## ⚡ Performance Testing

### Test Performance Impact
```ruby
# spec/performance/activeagent_performance_spec.rb
RSpec.describe "ActiveAgent Performance Impact" do
  let(:iterations) { 100 }

  it "has minimal impact on request processing time" do
    # Baseline without ActiveAgent
    baseline_time = Benchmark.measure do
      iterations.times { make_test_request }
    end

    # Configure ActiveAgent
    ActiveAgent::Client.configure do |config|
      config.api_key = "test-key"
      config.project_id = "test-project"
    end

    stub_request(:post, /api\.activeagent\.com/)
      .to_return(status: 200, body: '{"status":"ok"}')

    # Time with ActiveAgent
    activeagent_time = Benchmark.measure do
      iterations.times { make_test_request }
    end

    # Performance impact should be minimal (< 5%)
    impact_percentage = ((activeagent_time.real - baseline_time.real) / baseline_time.real) * 100
    expect(impact_percentage).to be < 5
  end

  private

  def make_test_request
    get "/test_endpoint"
  end
end
```

### Test Memory Usage
```ruby
# spec/performance/memory_usage_spec.rb
RSpec.describe "Memory Usage" do
  it "doesn't cause memory leaks" do
    ActiveAgent::Client.configure do |config|
      config.api_key = "test-key"
    end

    stub_request(:post, /api\.activeagent\.com/)
      .to_return(status: 200, body: '{"status":"ok"}')

    # Measure initial memory
    GC.start
    initial_memory = `ps -o rss= -p #{Process.pid}`.to_i

    # Generate many errors
    1000.times do |i|
      begin
        raise StandardError, "Test error #{i}"
      rescue => e
        ActiveAgent::Client.track_exception(e)
      end
    end

    # Force cleanup
    ActiveAgent::Client.flush
    GC.start

    # Measure final memory
    final_memory = `ps -o rss= -p #{Process.pid}`.to_i
    memory_increase = final_memory - initial_memory

    # Memory increase should be reasonable (< 50MB)
    expect(memory_increase).to be < 50_000 # KB
  end
end
```

## 🎯 Production Simulation Tests

### Test with High Volume
```ruby
# spec/load/high_volume_spec.rb
RSpec.describe "High Volume Testing" do
  before do
    ActiveAgent::Client.configure do |config|
      config.api_key = "test-key"
      config.batch_size = 10
      config.flush_interval = 1
    end

    stub_request(:post, /api\.activeagent\.com/)
      .to_return(status: 200, body: '{"status":"ok"}')
  end

  it "handles high volume of exceptions" do
    # Simulate high error volume
    threads = []

    10.times do
      threads << Thread.new do
        100.times do |i|
          begin
            raise StandardError, "High volume error #{i}"
          rescue => e
            ActiveAgent::Client.track_exception(e)
          end
          sleep(0.01) # Small delay to simulate real usage
        end
      end
    end

    threads.each(&:join)
    ActiveAgent::Client.flush

    # Verify all requests were batched and sent
    expect(WebMock).to have_requested(:post, /api\.activeagent\.com/).at_least_times(100)
  end
end
```

### Test API Failures
```ruby
# spec/resilience/api_failure_spec.rb
RSpec.describe "API Failure Resilience" do
  before do
    ActiveAgent::Client.configure do |config|
      config.api_key = "test-key"
      config.retry_count = 2
    end
  end

  it "handles API failures gracefully" do
    # Stub API to fail initially, then succeed
    stub_request(:post, /api\.activeagent\.com/)
      .to_return(status: 500).times(2)
      .then.to_return(status: 200, body: '{"status":"ok"}')

    # This should not raise an error
    expect {
      ActiveAgent::Client.track_exception(StandardError.new("Test"))
    }.not_to raise_error

    # Verify retries were attempted
    expect(WebMock).to have_requested(:post, /api\.activeagent\.com/).times(3)
  end

  it "doesn't crash app when API is completely down" do
    stub_request(:post, /api\.activeagent\.com/)
      .to_return(status: 500)

    # App should continue working even if ActiveAgent API is down
    expect {
      100.times do
        ActiveAgent::Client.track_exception(StandardError.new("Test"))
      end
    }.not_to raise_error
  end
end
```

## 🚀 Pre-Production Checklist

### Test Script for Manual Verification
```ruby
# script/test_activeagent.rb
#!/usr/bin/env ruby

puts "🧪 Testing ActiveAgent Integration..."

# Test 1: Configuration
puts "\n1. Testing Configuration..."
ActiveAgent::Client.configure do |config|
  config.api_key = ENV['ACTIVE_AGENT_API_KEY'] || 'test-key'
  config.project_id = ENV['ACTIVE_AGENT_PROJECT_ID'] || 'test-project'
  config.environment = 'test'
end

if ActiveAgent::Client.configured?
  puts "✅ Configuration successful"
else
  puts "❌ Configuration failed"
  exit 1
end

# Test 2: Exception Tracking
puts "\n2. Testing Exception Tracking..."
begin
  raise StandardError, "Test exception for ActiveAgent"
rescue => e
  ActiveAgent::Client.track_exception(e, context: { test: true })
  puts "✅ Exception tracked"
end

# Test 3: Event Tracking
puts "\n3. Testing Event Tracking..."
ActiveAgent::Client.track_event(
  'test_event',
  { component: 'test_script', timestamp: Time.current },
  user_id: 'test-user'
)
puts "✅ Event tracked"

# Test 4: Performance Tracking
puts "\n4. Testing Performance Tracking..."
ActiveAgent::Client.track_performance(
  'test_operation',
  150.5,
  metadata: { test: true }
)
puts "✅ Performance tracked"

# Test 5: Flush and Shutdown
puts "\n5. Testing Flush and Shutdown..."
ActiveAgent::Client.flush
ActiveAgent::Client.shutdown
puts "✅ Flush and shutdown successful"

puts "\n🎉 All tests passed! ActiveAgent is ready for production."
```

## 📋 Running the Tests

### Complete Test Suite
```bash
# Run all tests
bundle exec rspec

# Run specific test types
bundle exec rspec spec/active_agent/          # Unit tests
bundle exec rspec spec/integration/           # Integration tests
bundle exec rspec spec/features/              # End-to-end tests
bundle exec rspec spec/performance/           # Performance tests

# Run with coverage
COVERAGE=true bundle exec rspec

# Run manual test script
ruby script/test_activeagent.rb
```

### CI/CD Integration
```yaml
# .github/workflows/test.yml
name: Test ActiveAgent Integration

on: [push, pull_request]

jobs:
  test:
    runs-on: ubuntu-latest

    steps:
    - uses: actions/checkout@v2
    - name: Setup Ruby
      uses: ruby/setup-ruby@v1
      with:
        ruby-version: 3.2.0
        bundler-cache: true

    - name: Run tests
      run: |
        bundle exec rspec
        ruby script/test_activeagent.rb
      env:
        ACTIVE_AGENT_API_KEY: ${{ secrets.ACTIVE_AGENT_API_KEY }}
        ACTIVE_AGENT_PROJECT_ID: ${{ secrets.ACTIVE_AGENT_PROJECT_ID }}
```

This comprehensive testing approach ensures your Rails application and ActiveAgent gem integration is thoroughly tested before production deployment, covering functionality, performance, and resilience scenarios.
