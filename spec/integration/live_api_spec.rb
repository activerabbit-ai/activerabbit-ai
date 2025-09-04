require 'spec_helper'
require 'time'

# These tests run against a live ActiveRabbit API instance
# Set LIVE_API_TEST=true to enable these tests
# Requires actual API running on localhost:3000

RSpec.describe 'ActiveRabbit Live API Integration', type: :integration do
  let(:api_key) { ENV['ACTIVERABBIT_API_KEY'] || '9b3344ba8775e8ab11fd47e04534ae81e938180a23de603e60b5ec4346652f06' }
  let(:project_id) { ENV['ACTIVERABBIT_PROJECT_ID'] || '1' }
  let(:api_url) { ENV['ACTIVERABBIT_API_URL'] || 'http://localhost:3000' }
  let(:configuration) do
    ActiveRabbit::Client::Configuration.new.tap do |config|
      config.api_key = api_key
      config.project_id = project_id
      config.api_url = api_url
    end
  end
  let(:client) { ActiveRabbit::Client::HttpClient.new(configuration) }

  # Only run these tests if explicitly enabled
  before(:all) do
    skip "Live API tests disabled. Set LIVE_API_TEST=true to enable" unless ENV['LIVE_API_TEST'] == 'true'
    # Disable WebMock for live tests
    WebMock.disable_net_connect!(allow_localhost: true)
  end

  after(:all) do
    # Re-enable WebMock restrictions after live tests
    WebMock.disable_net_connect! if ENV['LIVE_API_TEST'] == 'true'
  end

  before do
    # Configure ActiveRabbit for live testing
    ActiveRabbit::Client.configure do |config|
      config.api_key = api_key
      config.project_id = project_id
      config.api_url = api_url
    end
  end

  describe 'Live API Connection' do
    it 'successfully connects to the live API' do
      response = nil

      expect {
        response = client.test_connection
      }.not_to raise_error

      expect(response).to be_truthy
    end

    it 'returns expected connection response format' do
      # This test will actually hit the live API
      response = client.test_connection

      # If we get here, the API returned a successful response
      expect(response).to be_truthy
    end
  end

  describe 'Live Error Tracking' do
    let(:test_error_data) do
      {
        exception_class: 'LiveTestError',
        message: 'This is a live test error from RSpec',
        backtrace: [
          {
            filename: 'live_api_spec.rb',
            lineno: __LINE__,
            method: 'test_error_tracking',
            line: "live_api_spec.rb:#{__LINE__}:in `test_error_tracking'"
          }
        ],
        fingerprint: "live_test_#{Time.now.to_i}",
        timestamp: Time.now.iso8601(3),
        environment: 'test',
        context: {
          request: {
            method: 'POST',
            path: '/live_test',
            user_agent: 'RSpec Live Test',
            remote_ip: '127.0.0.1'
          },
          user: {
            id: 'test_user_123'
          },
          extra: {
            test_run: true,
            rspec_version: RSpec::Core::Version::STRING
          }
        },
        event_type: 'error'
      }
    end

    it 'successfully tracks errors in live API' do
      response = nil

      expect {
        response = client.post_event(test_error_data)
      }.not_to raise_error

      expect(response).to be_truthy
    end

    it 'handles error validation correctly' do
      invalid_data = test_error_data.except(:exception_class, :message)

      expect {
        client.post_event(invalid_data)
      }.to raise_error(ActiveRabbit::Client::APIError)
    end
  end

  describe 'Live Performance Tracking' do
    let(:test_performance_data) do
      {
        name: 'LiveTestController#performance_test',
        duration_ms: 125.5,
        db_duration_ms: 45.2,
        view_duration_ms: 30.1,
        allocations: 1500,
        sql_queries_count: 3,
        metadata: {
          controller: 'LiveTestController',
          action: 'performance_test',
          method: 'GET',
          path: '/live_test/performance',
          status: 200,
          format: 'json'
        },
        timestamp: Time.now.iso8601(3),
        environment: 'test',
        user_id: 'test_user_456',
        request_id: SecureRandom.uuid,
        event_type: 'performance'
      }
    end

    it 'successfully tracks performance in live API' do
      response = nil

      expect {
        response = client.post_event(test_performance_data)
      }.not_to raise_error

      expect(response).to be_truthy
    end

    it 'handles performance validation correctly' do
      invalid_data = test_performance_data.except(:duration_ms, :name)

      expect {
        client.post_event(invalid_data)
      }.to raise_error(ActiveRabbit::Client::APIError)
    end
  end

  describe 'Live Batch Processing' do
    let(:test_batch_events) do
      [
        {
          event_type: 'error',
          data: {
            exception_class: 'BatchTestError1',
            message: 'Batch test error 1',
            timestamp: Time.now.iso8601(3),
            environment: 'test',
            fingerprint: "batch_error_1_#{Time.now.to_i}"
          }
        },
        {
          event_type: 'performance',
          data: {
            name: 'BatchTestController#action1',
            duration_ms: 89.3,
            timestamp: Time.now.iso8601(3),
            environment: 'test'
          }
        },
        {
          event_type: 'error',
          data: {
            exception_class: 'BatchTestError2',
            message: 'Batch test error 2',
            timestamp: Time.now.iso8601(3),
            environment: 'test',
            fingerprint: "batch_error_2_#{Time.now.to_i}"
          }
        }
      ]
    end

    it 'successfully processes batch events in live API' do
      response = nil

      expect {
        response = client.post_batch(test_batch_events)
      }.not_to raise_error

      expect(response).to be_truthy
    end

    it 'handles empty batch correctly' do
      expect {
        client.post_batch([])
      }.to raise_error(ActiveRabbit::Client::APIError)
    end
  end

  describe 'Live Authentication and Authorization' do
    context 'with invalid API key' do
      let(:invalid_configuration) do
        ActiveRabbit::Client::Configuration.new.tap do |config|
          config.api_key = 'invalid_key'
          config.project_id = project_id
          config.api_url = api_url
        end
      end
      let(:invalid_client) { ActiveRabbit::Client::HttpClient.new(invalid_configuration) }

      it 'raises authentication error' do
        expect {
          invalid_client.test_connection
        }.to raise_error(ActiveRabbit::Client::APIError)
      end
    end

    context 'with invalid project ID' do
      let(:invalid_project_configuration) do
        ActiveRabbit::Client::Configuration.new.tap do |config|
          config.api_key = api_key
          config.project_id = '99999'
          config.api_url = api_url
        end
      end
      let(:invalid_project_client) { ActiveRabbit::Client::HttpClient.new(invalid_project_configuration) }

      it 'raises project not found error' do
        expect {
          invalid_project_client.test_connection
        }.to raise_error(ActiveRabbit::Client::APIError)
      end
    end
  end

  describe 'Live Error Recovery and Retry' do
    it 'handles temporary network issues gracefully' do
      # This test might be flaky depending on network conditions
      # but it's useful for testing real-world scenarios

      10.times do |i|
        test_data = {
          exception_class: 'RetryTestError',
          message: "Retry test error #{i}",
          timestamp: Time.now.iso8601(3),
          environment: 'test',
          fingerprint: "retry_test_#{i}_#{Time.now.to_i}",
          event_type: 'error'
        }

        expect {
          client.post_event(test_data)
        }.not_to raise_error

        # Small delay between requests to avoid overwhelming the API
        sleep(0.1)
      end
    end
  end

  describe 'Live API Response Times' do
    it 'responds within acceptable time limits' do
      start_time = Time.now

      client.test_connection

      response_time = Time.now - start_time

      # API should respond within 2 seconds for connection test
      expect(response_time).to be < 2.0
    end

    it 'handles concurrent requests efficiently' do
      threads = []
      results = []

      # Make 5 concurrent requests
      5.times do |i|
        threads << Thread.new do
          test_data = {
            exception_class: 'ConcurrentTestError',
            message: "Concurrent test error #{i}",
            timestamp: Time.now.iso8601(3),
            environment: 'test',
            fingerprint: "concurrent_test_#{i}_#{Time.now.to_i}",
            event_type: 'error'
          }

          begin
            result = client.post_event(test_data)
            results << { thread: i, success: true, result: result }
          rescue => e
            results << { thread: i, success: false, error: e.message }
          end
        end
      end

      threads.each(&:join)

      # All requests should succeed
      successful_requests = results.count { |r| r[:success] }
      expect(successful_requests).to eq(5)
    end
  end

  describe 'Live Data Validation and Processing' do
    it 'properly processes complex error contexts' do
      complex_error_data = {
        exception_class: 'ComplexTestError',
        message: 'This is a complex test error with lots of context',
        backtrace: Array.new(20) do |i|
          {
            filename: "complex_file_#{i}.rb",
            lineno: i * 10 + 5,
            method: "complex_method_#{i}",
            line: "complex_file_#{i}.rb:#{i * 10 + 5}:in `complex_method_#{i}'"
          }
        end,
        fingerprint: "complex_test_#{Time.now.to_i}",
        timestamp: Time.now.iso8601(3),
        environment: 'test',
        context: {
          request: {
            method: 'POST',
            path: '/complex/test/path',
            user_agent: 'ComplexTestAgent/1.0',
            remote_ip: '192.168.1.100',
            headers: {
              'Accept' => 'application/json',
              'Content-Type' => 'application/json'
            },
            params: {
              'test_param_1' => 'value1',
              'test_param_2' => 'value2',
              'nested' => {
                'param' => 'nested_value'
              }
            }
          },
          user: {
            id: 'complex_user_789',
            email: 'test@example.com',
            role: 'admin'
          },
          server: {
            hostname: 'test-server-01',
            pid: Process.pid,
            thread_id: Thread.current.object_id
          },
          extra: {
            custom_field_1: 'custom_value_1',
            custom_field_2: 42,
            custom_field_3: true,
            timestamp_created: Time.now.iso8601
          }
        },
        event_type: 'error'
      }

      expect {
        client.post_event(complex_error_data)
      }.not_to raise_error
    end
  end
end


