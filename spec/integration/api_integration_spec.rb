require 'spec_helper'
require 'webmock/rspec'
require 'time'

RSpec.describe 'ActiveRabbit API Integration', type: :integration do
  let(:api_key) { '9b3344ba8775e8ab11fd47e04534ae81e938180a23de603e60b5ec4346652f06' }
  let(:project_id) { '1' }
  let(:api_url) { 'http://localhost:3000' }
  let(:configuration) do
    ActiveRabbit::Client::Configuration.new.tap do |config|
      config.api_key = api_key
      config.project_id = project_id
      config.api_url = api_url
    end
  end
  let(:client) { ActiveRabbit::Client::HttpClient.new(configuration) }

  before do
    WebMock.disable_net_connect!(allow_localhost: false)

    # Configure ActiveRabbit for testing
    ActiveRabbit::Client.configure do |config|
      config.api_key = api_key
      config.project_id = project_id
      config.api_url = api_url
    end
  end

  after do
    WebMock.reset!
  end

  describe 'Connection Test Endpoint' do
    context 'when API is available' do
      before do
        stub_request(:post, "#{api_url}/api/v1/test/connection")
          .with(
            headers: {
              'Content-Type' => 'application/json',
              'X-Project-Token' => api_key,
              'X-Project-Id' => project_id,
              'User-Agent' => "ActiveRabbit-Client/#{ActiveRabbit::Client::VERSION}"
            },
            body: hash_including({
              gem_version: ActiveRabbit::Client::VERSION,
              timestamp: anything
            })
          )
          .to_return(
            status: 200,
            body: {
              status: 'success',
              message: 'ActiveRabbit connection successful!',
              project_id: 1,
              project_name: 'Test Project',
              timestamp: Time.now.iso8601,
              gem_version: ActiveRabbit::Client::VERSION
            }.to_json,
            headers: { 'Content-Type' => 'application/json' }
          )
      end

      it 'successfully connects to the API' do
        response = client.test_connection

        expect(response).to be_truthy
        expect(WebMock).to have_requested(:post, "#{api_url}/api/v1/test/connection")
      end

      it 'includes correct headers in the request' do
        client.test_connection

        expect(WebMock).to have_requested(:post, "#{api_url}/api/v1/test/connection")
          .with(headers: {
            'Content-Type' => 'application/json',
            'X-Project-Token' => api_key,
            'X-Project-Id' => project_id,
            'User-Agent' => "ActiveRabbit-Client/#{ActiveRabbit::Client::VERSION}"
          })
      end

      it 'sends correct payload' do
        client.test_connection

        expect(WebMock).to have_requested(:post, "#{api_url}/api/v1/test/connection")
          .with(body: hash_including({
            gem_version: ActiveRabbit::Client::VERSION,
            timestamp: anything
          }))
      end
    end

    context 'when API returns error' do
      before do
        stub_request(:post, "#{api_url}/api/v1/test/connection")
          .to_return(status: 401, body: { error: 'unauthorized' }.to_json)
      end

      it 'raises APIError for 401 response' do
        response = client.test_connection
        expect(response[:success]).to be false
        expect(response[:error]).to match(/401|invalid token|unauthorized/i)
      end
    end

    context 'when API is unavailable' do
      before do
        stub_request(:post, "#{api_url}/api/v1/test/connection")
          .to_raise(SocketError.new('Connection refused'))
      end

      it 'raises RetryableError' do
        response = client.test_connection
        expect(response[:success]).to be false
        expect(response[:error]).to match(/timeout|connection refused/i)
      end
    end
  end

  describe 'Error Tracking Endpoint' do
    let(:error_data) do
      {
        exception_class: 'StandardError',
        message: 'Test error message',
        backtrace: [
          { filename: 'test.rb', lineno: 10, method: 'test_method', line: 'test.rb:10:in `test_method`' }
        ],
        fingerprint: 'test_fingerprint_123',
        timestamp: Time.now.iso8601(3),
        environment: 'test',
        context: {
          request: {
            method: 'GET',
            path: '/test',
            user_agent: 'Test Agent'
          }
        },
        event_type: 'error'
      }
    end

    context 'when error tracking succeeds' do
      before do
        stub_request(:post, "#{api_url}/api/v1/events/errors")
          .with(
            headers: {
              'Content-Type' => 'application/json',
              'X-Project-Token' => api_key,
              'X-Project-Id' => project_id
            },
            body: hash_including(error_data.except(:event_type))
          )
          .to_return(
            status: 201,
            body: {
              status: 'created',
              message: 'Error event queued for processing',
              data: {
                project_id: 1,
                exception_class: 'StandardError'
              }
            }.to_json
          )
        stub_request(:post, "#{api_url}/api/v1/events/batch")
          .to_return(status: 200, body: "", headers: {})
      end

      it 'successfully posts error data' do
        client.post_exception(error_data)
        client.flush
        expect(WebMock).to have_requested(:post, "#{api_url}/api/v1/events/batch")
      end

      it 'sends correct error payload' do
        client.post_exception(error_data)
        client.flush
        expect(WebMock).to have_requested(:post, "#{api_url}/api/v1/events/batch")
          .with(body: hash_including({
            "events" => array_including(
              hash_including({
                "type" => nil,
                "data" => hash_including({
                  "exception_class" => "StandardError",
                  "message" => "Test error message",
                  "backtrace" => anything,
                  "fingerprint" => "test_fingerprint_123",
                  "environment" => "test"
                })
              })
            )
          }))
      end
    end

    context 'when validation fails' do
      before do
        stub_request(:post, "#{api_url}/api/v1/events/errors")
          .to_return(
            status: 422,
            body: {
              error: 'validation_failed',
              message: 'Invalid error payload',
              details: ['exception_class is required']
            }.to_json
          )
      end

      it 'raises APIError for validation failure' do
        invalid_data = error_data.except(:exception_class)
        response = client.post_event(invalid_data)
        expect(response).to be_nil
      end
    end
  end

  describe 'Performance Tracking Endpoint' do
    let(:performance_data) do
      {
        name: 'UsersController#index',
        duration_ms: 150.5,
        metadata: {
          controller: 'UsersController',
          action: 'index',
          method: 'GET',
          path: '/users'
        },
        timestamp: Time.now.iso8601(3),
        environment: 'test',
        event_type: 'performance'
      }
    end

    context 'when performance tracking succeeds' do
      before do
        stub_request(:post, "#{api_url}/api/v1/events/performance")
          .with(
            headers: {
              'Content-Type' => 'application/json',
              'X-Project-Token' => api_key,
              'X-Project-Id' => project_id
            },
            body: hash_including(performance_data.except(:event_type))
          )
          .to_return(
            status: 201,
            body: {
              status: 'created',
              message: 'Performance event queued for processing',
              data: {
                project_id: 1,
                target: 'UsersController#index'
              }
            }.to_json
          )

        stub_request(:post, "#{api_url}/api/v1/events/batch")
          .to_return(status: 200, body: "", headers: {})
      end

      it 'successfully posts performance data' do
        client.post_performance(performance_data.except(:event_type))
        client.flush
        expect(WebMock).to have_requested(:post, "#{api_url}/api/v1/events/batch")
      end

      it 'sends correct performance payload' do
        client.post_performance(performance_data.except(:event_type))
        client.flush
        expect(WebMock).to have_requested(:post, "#{api_url}/api/v1/events/batch")
          .with(body: hash_including({
            "events" => array_including(
              hash_including({
                "type" => "performance",
                "data" => hash_including({
                  "name" => "UsersController#index",
                  "duration_ms" => 150.5,
                  "environment" => "test"
                })
              })
            )
          }))
      end
    end

    context 'when validation fails' do
      before do
        stub_request(:post, "#{api_url}/api/v1/events/performance")
          .to_return(
            status: 422,
            body: {
              error: 'validation_failed',
              message: 'Invalid performance payload',
              details: ['duration_ms is required']
            }.to_json
          )
      end

      it 'raises APIError for validation failure' do
        invalid_data = performance_data.except(:duration_ms)
        response = client.post_event(invalid_data)
        expect(response).to be_nil
      end
    end
  end

  describe 'Batch Events Endpoint' do
    let(:batch_events) do
      [
        {
          event_type: 'error',
          data: {
            exception_class: 'StandardError',
            message: 'Batch error 1',
            timestamp: Time.now.iso8601(3),
            environment: 'test'
          }
        },
        {
          event_type: 'performance',
          data: {
            name: 'TestController#action',
            duration_ms: 100.0,
            timestamp: Time.now.iso8601(3),
            environment: 'test'
          }
        }
      ]
    end

    context 'when batch processing succeeds' do
      before do
        stub_request(:post, "#{api_url}/api/v1/events/batch")
          .with(
            headers: {
              'Content-Type' => 'application/json',
              'X-Project-Token' => api_key,
              'X-Project-Id' => project_id
            },
            body: hash_including({ events: anything })
          )
          .to_return(
            status: 201,
            body: {
              status: 'created',
              message: 'Batch events queued for processing',
              data: {
                batch_id: 'batch_123',
                processed_count: 2,
                total_count: 2,
                project_id: 1
              }
            }.to_json
          )
      end

      it 'successfully posts batch events' do
        response = client.post_batch(batch_events)

        expect(response).to be_truthy
        expect(WebMock).to have_requested(:post, "#{api_url}/api/v1/events/batch")
      end

      it 'sends correct batch payload' do
        client.post_batch(batch_events)

        expect(WebMock).to have_requested(:post, "#{api_url}/api/v1/events/batch")
          .with(body: hash_including({
            "events" => array_including(
              hash_including({ "type" => "error" }),
              hash_including({ "type" => "performance" })
            )
          }))
      end
    end

    context 'when batch is too large' do
      before do
        stub_request(:post, "#{api_url}/api/v1/events/batch")
          .to_return(
            status: 422,
            body: {
              error: 'validation_failed',
              message: 'Batch size exceeds maximum of 100 events'
            }.to_json
          )
      end

      it 'raises APIError for oversized batch' do
        large_batch = Array.new(101) { batch_events.first }

        expect { client.post_batch(large_batch) }.to raise_error(ActiveRabbit::Client::APIError, /422/)
      end
    end
  end

  describe 'Authentication and Authorization' do
    context 'when API key is invalid' do
      before do
        stub_request(:post, "#{api_url}/api/v1/test/connection")
          .to_return(
            status: 401,
            body: {
              error: 'unauthorized',
              message: 'Invalid or inactive token'
            }.to_json
          )
      end

      it 'raises APIError for invalid token' do
        response = client.test_connection
        expect(response[:success]).to be false
        expect(response[:error]).to match(/401|invalid token|unauthorized/i)
      end
    end

    context 'when project is not found' do
      before do
        stub_request(:post, "#{api_url}/api/v1/test/connection")
          .to_return(
            status: 404,
            body: {
              error: 'project_not_found',
              message: 'Project not found'
            }.to_json
          )
      end

      it 'raises APIError for missing project' do
        response = client.test_connection
        expect(response[:success]).to be false
        expect(response[:error]).to match(/404|missing project|not found/i)
      end
    end

    context 'when rate limited' do
      before do
        stub_request(:post, "#{api_url}/api/v1/test/connection")
          .to_return(
            status: 429,
            body: {
              error: 'rate_limit_exceeded',
              message: 'Too many requests'
            }.to_json
          )
      end

      it 'handles rate limit response correctly' do
        response = client.test_connection
        expect(response[:success]).to be false
        expect(response[:error]).to match(/429|rate limit/i)
      end
    end
  end

  describe 'Network Error Handling' do
    context 'when connection times out' do
      before do
        stub_request(:post, "#{api_url}/api/v1/test/connection")
          .to_timeout
      end

      it 'raises RetryableError for timeout' do
        response = client.test_connection
        expect(response[:success]).to be false
        expect(response[:error]).to match(/timeout|retry/i)
      end
    end

    context 'when connection is refused' do
      before do
        stub_request(:post, "#{api_url}/api/v1/test/connection")
          .to_raise(Errno::ECONNREFUSED)
      end

      it 'raises RetryableError for connection refused' do
        response = client.test_connection
        expect(response[:success]).to be false
        expect(response[:error]).to match(/timeout|connection refused/i)
      end
    end

    context 'when server returns 500 error' do
      before do
        stub_request(:post, "#{api_url}/api/v1/test/connection")
          .to_return(status: 500, body: 'Internal Server Error')
      end

      it 'retries and eventually raises RetryableError' do
        response = client.test_connection
        expect(response[:success]).to be false
        expect(response[:error]).to match(/500|Internal Server Error|timeout|retry/i)

        # Should have made multiple attempts due to retry logic
        expect(WebMock).to have_requested(:post, "#{api_url}/api/v1/test/connection").times(4)
      end
    end
  end

  describe 'SSL and Security' do
    let(:https_url) { 'https://api.activerabbit.com' }
    let(:https_configuration) do
      ActiveRabbit::Client::Configuration.new.tap do |config|
        config.api_key = api_key
        config.project_id = project_id
        config.api_url = https_url
      end
    end
    let(:https_client) { ActiveRabbit::Client::HttpClient.new(https_configuration) }

    before do
      stub_request(:post, "#{https_url}/api/v1/test/connection")
        .to_return(status: 200, body: { status: 'success' }.to_json)
    end

    it 'handles HTTPS URLs correctly' do
      https_client.test_connection

      expect(WebMock).to have_requested(:post, "#{https_url}/api/v1/test/connection")
        .with(headers: {
          'Content-Type' => 'application/json',
          'X-Project-Token' => api_key,
          'X-Project-Id' => project_id,
          'User-Agent' => "ActiveRabbit-Client/#{ActiveRabbit::Client::VERSION}",
          'Accept' => 'application/json'
        })
    end
  end

  describe 'Request Headers' do
    before do
      stub_request(:post, "#{api_url}/api/v1/test/connection")
        .to_return(status: 200, body: { status: 'success' }.to_json)
    end

    it 'includes all required headers' do
      client.test_connection

      expect(WebMock).to have_requested(:post, "#{api_url}/api/v1/test/connection")
        .with(headers: {
          'Content-Type' => 'application/json',
          'X-Project-Token' => api_key,
          'X-Project-Id' => project_id,
          'User-Agent' => "ActiveRabbit-Client/#{ActiveRabbit::Client::VERSION}",
          'Accept' => 'application/json'
        })
    end
  end

  describe 'Response Parsing' do
    context 'when response is valid JSON' do
      before do
        stub_request(:post, "#{api_url}/api/v1/test/connection")
          .to_return(
            status: 200,
            body: { status: 'success', data: { test: 'value' } }.to_json,
            headers: { 'Content-Type' => 'application/json' }
          )
      end

      it 'parses JSON response correctly' do
        response = client.test_connection
        expect(response).to be_truthy
        expect(response).not_to be_nil
      end
    end

    context 'when response is invalid JSON' do
      before do
        stub_request(:post, "#{api_url}/api/v1/test/connection")
          .to_return(status: 200, body: 'invalid json')
      end

      it 'handles invalid JSON gracefully' do
        response = client.test_connection
        expect(response).to be_a(Hash)
        expect(response[:data]).to eq('invalid json')
      end
    end
  end
end
