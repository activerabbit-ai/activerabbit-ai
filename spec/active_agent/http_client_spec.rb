# frozen_string_literal: true

require "webmock/rspec"

RSpec.describe ActiveRabbit::Client::HttpClient do
  let(:configuration) do
    config = ActiveRabbit::Client::Configuration.new
    config.api_key = "test-api-key"
    config.api_url = "https://api.example.com"
    config.project_id = "test-project"
    config.timeout = 30
    config.open_timeout = 10
    config.retry_count = 2
    config.retry_delay = 1
    config
  end

  let(:http_client) { described_class.new(configuration) }

  before do
    WebMock.disable_net_connect!
  end

  after do
    WebMock.reset!
  end

  describe "#initialize" do
    it "initializes with configuration" do
      expect(http_client.configuration).to eq(configuration)
    end

    it "sets up request queue and timer" do
      expect(http_client.instance_variable_get(:@request_queue)).to be_a(Concurrent::Array)
      expect(http_client.instance_variable_get(:@batch_timer)).to be_nil
      expect(http_client.instance_variable_get(:@shutdown)).to be false
    end
  end

  describe "#post_event" do
    it "enqueues a POST request to events endpoint" do
      event_data = { name: "test_event", properties: { key: "value" } }

      expect(http_client).to receive(:enqueue_request).with(:post, "api/v1/events", event_data)

      http_client.post_event(event_data)
    end
  end

  describe "#post_exception" do
    it "enqueues a POST request to exceptions endpoint with event_type" do
      exception_data = { type: "StandardError", message: "Test error" }
      expected_data = exception_data.merge(event_type: 'error')

      expect(http_client).to receive(:enqueue_request).with(:post, "api/v1/events/errors", expected_data)

      http_client.post_exception(exception_data)
    end
  end

  describe "#post_performance" do
    it "enqueues a POST request to performance endpoint with event_type" do
      performance_data = { name: "test_operation", duration_ms: 1500 }
      expected_data = performance_data.merge(event_type: 'performance')

      expect(http_client).to receive(:enqueue_request).with(:post, "api/v1/events/performance", expected_data)

      http_client.post_performance(performance_data)
    end
  end

  describe "#test_connection" do
    context "when connection succeeds" do
      it "returns success response" do
        stub_request(:post, "https://api.example.com/api/v1/test/connection")
          .with(
            headers: {
              'Content-Type' => 'application/json',
              'Accept' => 'application/json',
              'User-Agent' => "ActiveRabbit-Ruby/#{ActiveRabbit::Client::VERSION}",
              'X-Project-Token' => 'test-api-key',
              'X-Project-ID' => 'test-project'
            },
            body: hash_including(:gem_version, :timestamp)
          )
          .to_return(status: 200, body: '{"status": "ok"}')

        result = http_client.test_connection

        expect(result[:success]).to be true
        expect(result[:data]).to eq({"status" => "ok"})
      end
    end

    context "when connection fails" do
      it "returns failure response" do
        stub_request(:post, "https://api.example.com/api/v1/test/connection")
          .to_raise(ActiveRabbit::Client::APIError.new("Connection failed"))

        result = http_client.test_connection

        expect(result[:success]).to be false
        expect(result[:error]).to eq("Connection failed")
      end
    end
  end

  describe "#make_request" do
    context "successful request" do
      it "makes HTTP request with proper headers" do
        stub_request(:post, "https://api.example.com/api/v1/test")
          .with(
            headers: {
              'Content-Type' => 'application/json',
              'Accept' => 'application/json',
              'User-Agent' => "ActiveRabbit-Ruby/#{ActiveRabbit::Client::VERSION}",
              'X-Project-Token' => 'test-api-key',
              'X-Project-ID' => 'test-project'
            },
            body: '{"test":"data"}'
          )
          .to_return(status: 200, body: '{"success":true}')

        result = http_client.send(:make_request, :post, "api/v1/test", { test: "data" })

        expect(result).to eq({"success" => true})
      end

      it "handles empty response body" do
        stub_request(:post, "https://api.example.com/api/v1/test")
          .to_return(status: 200, body: "")

        result = http_client.send(:make_request, :post, "api/v1/test", {})

        expect(result).to eq({})
      end

      it "handles non-JSON response body" do
        stub_request(:post, "https://api.example.com/api/v1/test")
          .to_return(status: 200, body: "OK")

        result = http_client.send(:make_request, :post, "api/v1/test", {})

        expect(result).to eq("OK")
      end
    end

    context "error responses" do
      it "raises RateLimitError for 429 status" do
        stub_request(:post, "https://api.example.com/api/v1/test")
          .to_return(status: 429, body: '{"error":"Rate limit exceeded"}')

        expect {
          http_client.send(:make_request, :post, "api/v1/test", {})
        }.to raise_error(ActiveRabbit::Client::RateLimitError, "Rate limit exceeded")
      end

      it "raises APIError for 4xx client errors" do
        stub_request(:post, "https://api.example.com/api/v1/test")
          .to_return(status: 400, body: '{"error":"Bad request"}')

        expect {
          http_client.send(:make_request, :post, "api/v1/test", {})
        }.to raise_error(ActiveRabbit::Client::APIError, "Client error (400): Bad request")
      end

      it "raises APIError for 5xx server errors" do
        stub_request(:post, "https://api.example.com/api/v1/test")
          .to_return(status: 500, body: '{"error":"Internal server error"}')

        expect {
          http_client.send(:make_request, :post, "api/v1/test", {})
        }.to raise_error(ActiveRabbit::Client::APIError, "Server error (500): Internal server error")
      end
    end

    context "retry logic" do
      it "retries on network errors" do
        stub_request(:post, "https://api.example.com/api/v1/test")
          .to_raise(Errno::ECONNREFUSED).then
          .to_return(status: 200, body: '{"success":true}')

        result = http_client.send(:make_request, :post, "api/v1/test", {})

        expect(result).to eq({"success" => true})
        expect(a_request(:post, "https://api.example.com/api/v1/test")).to have_been_made.times(2)
      end

      it "retries on 503 server errors" do
        stub_request(:post, "https://api.example.com/api/v1/test")
          .to_return(status: 503, body: '{"error":"Service unavailable"}').then
          .to_return(status: 200, body: '{"success":true}')

        result = http_client.send(:make_request, :post, "api/v1/test", {})

        expect(result).to eq({"success" => true})
        expect(a_request(:post, "https://api.example.com/api/v1/test")).to have_been_made.times(2)
      end

      it "gives up after max retries" do
        stub_request(:post, "https://api.example.com/api/v1/test")
          .to_raise(Errno::ECONNREFUSED)

        expect {
          http_client.send(:make_request, :post, "api/v1/test", {})
        }.to raise_error(ActiveRabbit::Client::APIError, /Connection failed after \d+ retries/)

        expect(a_request(:post, "https://api.example.com/api/v1/test")).to have_been_made.times(3) # initial + 2 retries
      end
    end

    context "timeout handling" do
      it "raises APIError on timeout" do
        stub_request(:post, "https://api.example.com/api/v1/test")
          .to_raise(Net::ReadTimeout)

        expect {
          http_client.send(:make_request, :post, "api/v1/test", {})
        }.to raise_error(ActiveRabbit::Client::APIError, /Request timeout after \d+ retries/)
      end
    end
  end

  describe "#flush" do
    context "when queue is empty" do
      it "does nothing" do
        expect(http_client).not_to receive(:post_batch)

        http_client.flush
      end
    end

    context "when queue has items" do
      it "sends batch request and clears queue" do
        # Add items to queue
        http_client.send(:enqueue_request, :post, "api/v1/events", { test: "data1" })
        http_client.send(:enqueue_request, :post, "api/v1/events", { test: "data2" })

        expect(http_client).to receive(:post_batch).with(array_including(
          hash_including(method: :post, path: "api/v1/events", data: { test: "data1" }),
          hash_including(method: :post, path: "api/v1/events", data: { test: "data2" })
        ))

        http_client.flush
      end
    end

    context "when batch sending fails" do
      it "logs error and raises APIError" do
        http_client.send(:enqueue_request, :post, "api/v1/events", { test: "data" })

        allow(http_client).to receive(:post_batch).and_raise(StandardError.new("Network error"))

        expect(configuration.logger).to receive(:error).with("[ActiveRabbit] Failed to send batch: Network error")

        expect {
          http_client.flush
        }.to raise_error(ActiveRabbit::Client::APIError, "Failed to send batch: Network error")
      end
    end
  end

  describe "#shutdown" do
    it "sets shutdown flag, stops timer, and flushes" do
      # Start timer by enqueueing something
      http_client.send(:enqueue_request, :post, "api/v1/events", { test: "data" })

      timer = http_client.instance_variable_get(:@batch_timer)

      expect(timer).to receive(:shutdown)
      expect(http_client).to receive(:flush)

      http_client.shutdown

      expect(http_client.instance_variable_get(:@shutdown)).to be true
    end
  end

  describe "batch processing" do
    it "starts batch timer when first request is enqueued" do
      expect(http_client.instance_variable_get(:@batch_timer)).to be_nil

      http_client.send(:enqueue_request, :post, "api/v1/events", { test: "data" })

      timer = http_client.instance_variable_get(:@batch_timer)
      expect(timer).to be_a(Concurrent::TimerTask)
    end

    it "flushes when queue reaches max size" do
      # Set a small queue size for testing
      allow(configuration).to receive(:queue_size).and_return(2)

      expect(http_client).to receive(:flush)

      # Add requests up to queue size
      http_client.send(:enqueue_request, :post, "api/v1/events", { test: "data1" })
      http_client.send(:enqueue_request, :post, "api/v1/events", { test: "data2" })
    end
  end
end
