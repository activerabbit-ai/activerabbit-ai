# frozen_string_literal: true

require "faraday"
require "faraday/retry"
require "json"
require "concurrent"

module ActiveRabbit
  module Client
    class HttpClient
      attr_reader :configuration

      def initialize(configuration)
        @configuration = configuration
        @connection = build_connection
        @request_queue = Concurrent::Array.new
        @batch_timer = nil
        @shutdown = false
      end

      def post_event(event_data)
        enqueue_request(:post, "api/v1/events", event_data)
      end

      def post_exception(exception_data)
        # Add event_type for batch processing
        exception_data_with_type = exception_data.merge(event_type: 'error')
        enqueue_request(:post, "api/v1/events/errors", exception_data_with_type)
      end

      def post_performance(performance_data)
        # Add event_type for batch processing
        performance_data_with_type = performance_data.merge(event_type: 'performance')
        enqueue_request(:post, "api/v1/events/performance", performance_data_with_type)
      end

      def post_batch(batch_data)
        make_request(:post, "api/v1/events/batch", { events: batch_data })
      end

      def flush
        return if @request_queue.empty?

        batch = @request_queue.shift(@request_queue.length)
        return if batch.empty?

        begin
          post_batch(batch)
        rescue => e
          configuration.logger&.error("[ActiveRabbit] Failed to send batch: #{e.message}")
          raise APIError, "Failed to send batch: #{e.message}"
        end
      end

      def shutdown
        @shutdown = true
        @batch_timer&.shutdown
        flush
      end

      private

      def build_connection
        Faraday.new(url: configuration.api_url) do |conn|
          conn.request :json
          conn.request :retry,
            max: configuration.retry_count,
            interval: configuration.retry_delay,
            backoff_factor: 2,
            retry_statuses: [429, 500, 502, 503, 504]

          conn.response :json
          conn.response :raise_error

          conn.options.timeout = configuration.timeout
          conn.options.open_timeout = configuration.open_timeout

          conn.headers["User-Agent"] = "ActiveRabbit-Ruby/#{VERSION}"
          conn.headers["X-Project-Token"] = configuration.api_key
          conn.headers["Content-Type"] = "application/json"

          if configuration.project_id
            conn.headers["X-Project-ID"] = configuration.project_id
          end
        end
      end

      def enqueue_request(method, path, data)
        return if @shutdown

        @request_queue << {
          method: method,
          path: path,
          data: data,
          timestamp: Time.now.to_f
        }

        # Start batch timer if not already running
        start_batch_timer if @batch_timer.nil? || @batch_timer.shutdown?

        # Flush if queue is full
        flush if @request_queue.length >= configuration.queue_size
      end

      def start_batch_timer
        @batch_timer = Concurrent::TimerTask.new(
          execution_interval: configuration.flush_interval,
          timeout_interval: configuration.flush_interval + 5
        ) do
          flush unless @request_queue.empty?
        end

        @batch_timer.execute
      end

      def make_request(method, path, data)
        response = @connection.public_send(method, path, data)

        case response.status
        when 200..299
          response.body
        when 429
          raise RateLimitError, "Rate limit exceeded"
        else
          raise APIError, "API request failed with status #{response.status}: #{response.body}"
        end
      rescue Faraday::TimeoutError => e
        raise APIError, "Request timeout: #{e.message}"
      rescue Faraday::ConnectionFailed => e
        raise APIError, "Connection failed: #{e.message}"
      rescue Faraday::Error => e
        raise APIError, "Request failed: #{e.message}"
      end
    end
  end
end

