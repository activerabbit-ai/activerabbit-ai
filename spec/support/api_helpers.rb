module ApiHelpers
  # Helper methods for API testing

  def stub_successful_connection(api_url: 'http://localhost:3000', api_key: 'test_key', project_id: '1')
    stub_request(:post, "#{api_url}/api/v1/test/connection")
      .with(
        headers: {
          'Content-Type' => 'application/json',
          'X-Project-Token' => api_key,
          'X-Project-ID' => project_id
        }
      )
      .to_return(
        status: 200,
        body: {
          status: 'success',
          message: 'ActiveRabbit connection successful!',
          project_id: project_id.to_i,
          project_name: 'Test Project',
          timestamp: Time.now.iso8601,
          gem_version: ActiveRabbit::Client::VERSION
        }.to_json,
        headers: { 'Content-Type' => 'application/json' }
      )
  end

  def stub_successful_error_tracking(api_url: 'http://localhost:3000', api_key: 'test_key', project_id: '1')
    stub_request(:post, "#{api_url}/api/v1/events/errors")
      .with(
        headers: {
          'Content-Type' => 'application/json',
          'X-Project-Token' => api_key,
          'X-Project-ID' => project_id
        }
      )
      .to_return(
        status: 201,
        body: {
          status: 'created',
          message: 'Error event queued for processing',
          data: {
            project_id: project_id.to_i,
            exception_class: 'TestError'
          }
        }.to_json,
        headers: { 'Content-Type' => 'application/json' }
      )
  end

  def stub_successful_performance_tracking(api_url: 'http://localhost:3000', api_key: 'test_key', project_id: '1')
    stub_request(:post, "#{api_url}/api/v1/events/performance")
      .with(
        headers: {
          'Content-Type' => 'application/json',
          'X-Project-Token' => api_key,
          'X-Project-ID' => project_id
        }
      )
      .to_return(
        status: 201,
        body: {
          status: 'created',
          message: 'Performance event queued for processing',
          data: {
            project_id: project_id.to_i,
            target: 'TestController#action'
          }
        }.to_json,
        headers: { 'Content-Type' => 'application/json' }
      )
  end

  def stub_successful_batch_processing(api_url: 'http://localhost:3000', api_key: 'test_key', project_id: '1')
    stub_request(:post, "#{api_url}/api/v1/events/batch")
      .with(
        headers: {
          'Content-Type' => 'application/json',
          'X-Project-Token' => api_key,
          'X-Project-ID' => project_id
        }
      )
      .to_return(
        status: 201,
        body: {
          status: 'created',
          message: 'Batch events queued for processing',
          data: {
            batch_id: SecureRandom.uuid,
            processed_count: 2,
            total_count: 2,
            project_id: project_id.to_i
          }
        }.to_json,
        headers: { 'Content-Type' => 'application/json' }
      )
  end

  def stub_api_error(endpoint:, status:, error_type:, message:, api_url: 'http://localhost:3000')
    stub_request(:post, "#{api_url}/api/v1/#{endpoint}")
      .to_return(
        status: status,
        body: {
          error: error_type,
          message: message
        }.to_json,
        headers: { 'Content-Type' => 'application/json' }
      )
  end

  def stub_network_error(endpoint:, error_class:, api_url: 'http://localhost:3000')
    stub_request(:post, "#{api_url}/api/v1/#{endpoint}")
      .to_raise(error_class)
  end

  def sample_error_data(overrides = {})
    {
      exception_class: 'StandardError',
      message: 'Test error message',
      backtrace: [
        {
          filename: 'test.rb',
          lineno: 10,
          method: 'test_method',
          line: 'test.rb:10:in `test_method`'
        }
      ],
      fingerprint: 'test_fingerprint',
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
    }.merge(overrides)
  end

  def sample_performance_data(overrides = {})
    {
      name: 'TestController#action',
      duration_ms: 150.5,
      db_duration_ms: 45.2,
      view_duration_ms: 30.1,
      allocations: 1500,
      sql_queries_count: 3,
      metadata: {
        controller: 'TestController',
        action: 'action',
        method: 'GET',
        path: '/test'
      },
      timestamp: Time.now.iso8601(3),
      environment: 'test',
      event_type: 'performance'
    }.merge(overrides)
  end

  def sample_batch_events(count = 2)
    Array.new(count) do |i|
      if i.even?
        {
          event_type: 'error',
          data: sample_error_data(
            exception_class: "BatchError#{i}",
            message: "Batch error #{i}",
            fingerprint: "batch_error_#{i}"
          ).except(:event_type)
        }
      else
        {
          event_type: 'performance',
          data: sample_performance_data(
            name: "BatchController#action#{i}",
            duration_ms: 100.0 + i
          ).except(:event_type)
        }
      end
    end
  end

  def expect_api_request(method:, endpoint:, api_url: 'http://localhost:3000', api_key: 'test_key', project_id: '1', body: nil)
    expectation = expect(WebMock).to have_requested(method, "#{api_url}/api/v1/#{endpoint}")
      .with(headers: {
        'Content-Type' => 'application/json',
        'X-Project-Token' => api_key,
        'X-Project-ID' => project_id,
        'User-Agent' => "ActiveRabbit-Client/#{ActiveRabbit::Client::VERSION}",
        'Accept' => 'application/json'
      })

    expectation = expectation.with(body: body) if body
    expectation
  end

  def configure_test_client(api_url: 'http://localhost:3000', api_key: 'test_key', project_id: '1')
    ActiveRabbit::Client.configure do |config|
      config.api_key = api_key
      config.project_id = project_id
      config.api_url = api_url
    end
  end
end

RSpec.configure do |config|
  config.include ApiHelpers, type: :integration
end
