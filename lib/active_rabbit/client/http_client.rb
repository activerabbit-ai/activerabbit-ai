# frozen_string_literal: true

require "net/http"
require "net/https"
require "json"
require "concurrent"
require "time"
require "uri"

module ActiveRabbit
  module Client
    # HTTP client specific errors
    class Error < StandardError; end
    class APIError < Error; end
    class RateLimitError < APIError; end
    class RetryableError < APIError; end

    class HttpClient
      attr_reader :configuration

      def initialize(configuration)
        @configuration = configuration
        @request_queue = Concurrent::Array.new
        @batch_timer = nil
        @shutdown = false
        @base_uri = URI(configuration.api_url)
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

      def test_connection
        response = make_request(:post, "api/v1/test/connection", {
          gem_version: ActiveRabbit::Client::VERSION,
          timestamp: Time.now.iso8601
        })
        { success: true, data: response }
      rescue => e
        { success: false, error: e.message }
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
        uri = URI.join(@base_uri, path)

        # Retry logic with exponential backoff
        retries = 0
        max_retries = configuration.retry_count

        begin
          response = perform_request(uri, method, data)
          handle_response(response)
        rescue RetryableError => e
          if retries < max_retries
            retries += 1
            sleep(configuration.retry_delay * (2 ** (retries - 1)))
            retry
          end
          raise APIError, e.message
        rescue Net::OpenTimeout, Net::ReadTimeout => e
          if retries < max_retries && should_retry_error?(e)
            retries += 1
            sleep(configuration.retry_delay * (2 ** (retries - 1))) # Exponential backoff
            retry
          end
          raise APIError, "Request timeout after #{retries} retries: #{e.message}"
        rescue Errno::ECONNREFUSED, Errno::EHOSTUNREACH, SocketError => e
          if retries < max_retries
            retries += 1
            sleep(configuration.retry_delay * (2 ** (retries - 1)))
            retry
          end
          raise APIError, "Connection failed after #{retries} retries: #{e.message}"
        rescue APIError, RateLimitError => e
          # Re-raise API errors as-is
          raise e
        rescue => e
          raise APIError, "Request failed: #{e.message}"
        end
      end

      def perform_request(uri, method, data)
        http = Net::HTTP.new(uri.host, uri.port)

        # Configure SSL if HTTPS
        if uri.scheme == 'https'
          http.use_ssl = true
          http.verify_mode = OpenSSL::SSL::VERIFY_PEER
        end

        # Set timeouts
        http.open_timeout = configuration.open_timeout
        http.read_timeout = configuration.timeout

        # Create request
        request = case method.to_s.downcase
                  when 'post'
                    Net::HTTP::Post.new(uri.path)
                  when 'get'
                    Net::HTTP::Get.new(uri.path)
                  when 'put'
                    Net::HTTP::Put.new(uri.path)
                  when 'delete'
                    Net::HTTP::Delete.new(uri.path)
                  else
                    raise ArgumentError, "Unsupported HTTP method: #{method}"
                  end

        # Set headers
        request['Content-Type'] = 'application/json'
        request['Accept'] = 'application/json'
        request['User-Agent'] = "ActiveRabbit-Client/#{ActiveRabbit::Client::VERSION}"
        request['X-Project-Token'] = configuration.api_key

        if configuration.project_id
          request['X-Project-ID'] = configuration.project_id
        end

        # Set body for POST/PUT requests
        if data && %w[post put].include?(method.to_s.downcase)
          request.body = JSON.generate(data)
        end

        http.request(request)
      end

      def handle_response(response)
        case response.code.to_i
        when 200..299
          # Parse JSON response if present
          if response.body && !response.body.empty?
            begin
              JSON.parse(response.body)
            rescue JSON::ParserError
              response.body
            end
          else
            {}
          end
        when 429
          raise RateLimitError, "Rate limit exceeded"
        when 400..499
          error_message = extract_error_message(response)
          raise APIError, "Client error (#{response.code}): #{error_message}"
        when 500..599
          error_message = extract_error_message(response)
          if should_retry_status?(response.code.to_i)
            raise RetryableError, "Server error (#{response.code}): #{error_message}"
          else
            raise APIError, "Server error (#{response.code}): #{error_message}"
          end
        else
          raise APIError, "Unexpected response code: #{response.code}"
        end
      end

      def extract_error_message(response)
        return "No error message" unless response.body

        begin
          parsed = JSON.parse(response.body)
          parsed['error'] || parsed['message'] || response.body
        rescue JSON::ParserError
          response.body
        end
      end

      def should_retry_error?(error)
        # Retry on network-level errors
        error.is_a?(Net::OpenTimeout) ||
        error.is_a?(Net::ReadTimeout) ||
        error.is_a?(Errno::ECONNREFUSED) ||
        error.is_a?(Errno::EHOSTUNREACH) ||
        error.is_a?(SocketError)
      end

      def should_retry_status?(status_code)
        # Retry on server errors and rate limits
        [429, 500, 502, 503, 504].include?(status_code)
      end
    end

  end
end
