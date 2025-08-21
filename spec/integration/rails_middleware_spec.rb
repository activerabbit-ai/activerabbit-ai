# frozen_string_literal: true

require 'rails_helper'
require 'webmock/rspec'

RSpec.describe "Rails Middleware Integration", type: :request do
  before do
    ActiveAgent::Client.configure do |config|
      config.api_key = "test-api-key"
      config.project_id = "test-project"
      config.api_url = "https://api.activeagent.com"
    end

    # Stub all ActiveAgent API calls
    stub_request(:post, "https://api.activeagent.com/api/v1/exceptions")
      .to_return(status: 200, body: '{"status":"ok"}')
    stub_request(:post, "https://api.activeagent.com/api/v1/events")
      .to_return(status: 200, body: '{"status":"ok"}')
    stub_request(:post, "https://api.activeagent.com/api/v1/performance")
      .to_return(status: 200, body: '{"status":"ok"}')
    stub_request(:post, "https://api.activeagent.com/api/v1/batch")
      .to_return(status: 200, body: '{"status":"ok"}')
  end

  after do
    # Clean up routes after each test
    Rails.application.reload_routes!
  end

  describe "Exception Middleware" do
    it "captures and reports unhandled exceptions" do
      # Add a test route that raises an exception
      Rails.application.routes.draw do
        get '/test_exception', to: proc { |env| raise StandardError, "Test exception message" }
      end

      expect {
        get '/test_exception'
      }.to raise_error(StandardError, "Test exception message")

      # Verify exception was reported to ActiveAgent
      expect(WebMock).to have_requested(:post, "https://api.activeagent.com/api/v1/exceptions")
        .with { |request|
          body = JSON.parse(request.body)
          body["type"] == "StandardError" &&
          body["message"] == "Test exception message" &&
          body["context"]["request"]["method"] == "GET" &&
          body["context"]["request"]["path"] == "/test_exception"
        }
    end

    it "includes request context in exception reports" do
      Rails.application.routes.draw do
        get '/test_context', to: proc { |env| raise ArgumentError, "Context test" }
      end

      expect {
        get '/test_context', params: { foo: 'bar' }, headers: { 'User-Agent' => 'TestAgent/1.0' }
      }.to raise_error(ArgumentError)

      expect(WebMock).to have_requested(:post, "https://api.activeagent.com/api/v1/exceptions")
        .with { |request|
          body = JSON.parse(request.body)
          body["context"]["request"]["query_string"].include?("foo=bar") &&
          body["context"]["request"]["user_agent"] == "TestAgent/1.0"
        }
    end

    it "doesn't interfere with normal request processing" do
      Rails.application.routes.draw do
        get '/test_normal', to: proc { |env| [200, {}, ['OK']] }
      end

      get '/test_normal'

      expect(response.status).to eq(200)
      expect(response.body).to eq('OK')

      # No exception should be reported
      expect(WebMock).not_to have_requested(:post, "https://api.activeagent.com/api/v1/exceptions")
    end
  end

  describe "Request Context Middleware" do
    it "sets request context for the duration of the request" do
      context_captured = nil

      Rails.application.routes.draw do
        get '/test_request_context', to: proc { |env|
          context_captured = Thread.current[:active_agent_request_context]
          [200, {}, ['OK']]
        }
      end

      get '/test_request_context', headers: { 'X-Request-ID' => 'test-request-123' }

      expect(context_captured).to include(
        method: 'GET',
        path: '/test_request_context',
        request_id: 'test-request-123'
      )
    end

    it "cleans up request context after request" do
      Rails.application.routes.draw do
        get '/test_cleanup', to: proc { |env| [200, {}, ['OK']] }
      end

      get '/test_cleanup'

      expect(Thread.current[:active_agent_request_context]).to be_nil
    end

    it "skips asset requests" do
      Rails.application.routes.draw do
        get '/assets/application.js', to: proc { |env|
          # This should not have request context set
          context = Thread.current[:active_agent_request_context]
          [200, {}, [context ? 'CONTEXT_SET' : 'NO_CONTEXT']]
        }
      end

      get '/assets/application.js'

      expect(response.body).to eq('NO_CONTEXT')
    end

    it "skips health check requests" do
      Rails.application.routes.draw do
        get '/health', to: proc { |env|
          context = Thread.current[:active_agent_request_context]
          [200, {}, [context ? 'CONTEXT_SET' : 'NO_CONTEXT']]
        }
      end

      get '/health'

      expect(response.body).to eq('NO_CONTEXT')
    end
  end

  describe "Performance Monitoring" do
    it "tracks controller action performance" do
      Rails.application.routes.draw do
        get '/slow_action', to: proc { |env|
          sleep(0.1) # Simulate slow action
          [200, {}, ['Slow response']]
        }
      end

      get '/slow_action'

      # Performance data should be sent
      expect(WebMock).to have_requested(:post, "https://api.activeagent.com/api/v1/performance")
        .with { |request|
          body = JSON.parse(request.body)
          body["name"] == "controller.action" &&
          body["duration_ms"] > 50 # Should be at least 50ms due to sleep
        }
    end
  end

  describe "Configuration Filtering" do
    it "respects ignored user agents" do
      ActiveAgent::Client.configuration.ignored_user_agents = [/TestBot/i]

      Rails.application.routes.draw do
        get '/bot_request', to: proc { |env| raise StandardError, "Bot error" }
      end

      expect {
        get '/bot_request', headers: { 'User-Agent' => 'TestBot/1.0' }
      }.to raise_error(StandardError)

      # Exception should not be reported due to ignored user agent
      expect(WebMock).not_to have_requested(:post, "https://api.activeagent.com/api/v1/exceptions")
    end

    it "respects ignored exceptions" do
      ActiveAgent::Client.configuration.ignored_exceptions = ['StandardError']

      Rails.application.routes.draw do
        get '/ignored_error', to: proc { |env| raise StandardError, "Ignored error" }
      end

      expect {
        get '/ignored_error'
      }.to raise_error(StandardError)

      # Exception should not be reported due to being in ignored list
      expect(WebMock).not_to have_requested(:post, "https://api.activeagent.com/api/v1/exceptions")
    end
  end

  describe "Error Handling Resilience" do
    it "continues working when ActiveAgent API is down" do
      # Stub API to return errors
      stub_request(:post, "https://api.activeagent.com/api/v1/exceptions")
        .to_return(status: 500, body: 'Internal Server Error')

      Rails.application.routes.draw do
        get '/test_resilience', to: proc { |env| raise RuntimeError, "Test error" }
      end

      # Application should still work normally even if ActiveAgent fails
      expect {
        get '/test_resilience'
      }.to raise_error(RuntimeError, "Test error")

      # Verify attempt was made to report exception
      expect(WebMock).to have_requested(:post, "https://api.activeagent.com/api/v1/exceptions")
    end

    it "doesn't crash when ActiveAgent configuration is invalid" do
      # Set invalid configuration
      ActiveAgent::Client.configuration.api_key = nil

      Rails.application.routes.draw do
        get '/test_invalid_config', to: proc { |env| raise StandardError, "Config test" }
      end

      # Should not crash the application
      expect {
        get '/test_invalid_config'
      }.to raise_error(StandardError, "Config test")

      # No API call should be made with invalid config
      expect(WebMock).not_to have_requested(:post, /api\.activeagent\.com/)
    end
  end

  describe "Thread Safety" do
    it "handles concurrent requests safely" do
      Rails.application.routes.draw do
        get '/concurrent_test', to: proc { |env|
          # Simulate some work
          sleep(0.01)
          raise StandardError, "Concurrent error #{Thread.current.object_id}"
        }
      end

      # Make multiple concurrent requests
      threads = []
      10.times do |i|
        threads << Thread.new do
          begin
            get '/concurrent_test'
          rescue => e
            # Expected to raise
          end
        end
      end

      threads.each(&:join)

      # Should have made multiple exception reports
      expect(WebMock).to have_requested(:post, "https://api.activeagent.com/api/v1/exceptions")
        .at_least_times(10)
    end
  end
end

