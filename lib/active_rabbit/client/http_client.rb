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
        # Sanitize data before any processing
        exception_data_with_type = stringify_and_sanitize(exception_data.merge(event_type: 'error'))

        # Primary endpoint path
        path = "/api/v1/events/errors"

        configuration.logger&.info("[ActiveRabbit] Sending exception to API...")
        configuration.logger&.debug("[ActiveRabbit] Exception payload (pre-JSON): #{safe_preview(exception_data_with_type)}")
        configuration.logger&.debug("[ActiveRabbit] Target path: #{path}")

        begin
          # Primary endpoint attempt
          configuration.logger&.info("[ActiveRabbit] Making request to primary endpoint: POST #{path}")
          response = make_request(:post, path, exception_data_with_type)
          configuration.logger&.info("[ActiveRabbit] Exception sent successfully (errors endpoint)")
          return response
        rescue => e
          configuration.logger&.error("[ActiveRabbit] Primary send failed: #{e.class}: #{e.message}")
          configuration.logger&.error("[ActiveRabbit] Primary error backtrace: #{e.backtrace&.first(3)}")
          configuration.logger&.debug("[ActiveRabbit] Falling back to /api/v1/events with type=error")

          begin
            # Fallback to generic events endpoint
            fallback_path = "/api/v1/events"
            fallback_body = { type: "error", data: exception_data_with_type }
            configuration.logger&.info("[ActiveRabbit] Making request to fallback endpoint: POST #{fallback_path}")
            response = make_request(:post, fallback_path, fallback_body)
            configuration.logger&.info("[ActiveRabbit] Exception sent via fallback endpoint")
            return response
          rescue => e2
            configuration.logger&.error("[ActiveRabbit] Fallback send failed: #{e2.class}: #{e2.message}")
            configuration.logger&.error("[ActiveRabbit] Fallback error backtrace: #{e2.backtrace&.first(3)}")
            configuration.logger&.error("[ActiveRabbit] All exception sending attempts failed")
            nil
          end
        end
      end

      def post_performance(performance_data)
        # Add event_type for batch processing
        performance_data_with_type = performance_data.merge(event_type: 'performance')
        enqueue_request(:post, "api/v1/events/performance", performance_data_with_type)
      end

      def post_batch(batch_data)
        # Transform batch data into the format the API expects
        events = batch_data.map do |event|
          {
            type: event[:data][:event_type] || event[:event_type] || event[:type],
            data: event[:data]
          }
        end

        # Send batch to API
        configuration.logger&.info("[ActiveRabbit] Sending batch of #{events.length} events...")
        response = make_request(:post, "/api/v1/events/batch", { events: events })
        configuration.logger&.info("[ActiveRabbit] Batch sent successfully")
        configuration.logger&.debug("[ActiveRabbit] Batch response: #{response.inspect}")
        response
      end

      def post(path, payload)
        uri = URI.join(@base_uri.to_s, path)
        req = Net::HTTP::Post.new(uri)
        req['Content-Type'] = 'application/json'
        req["X-Project-Token"] = configuration.api_key
        req.body = payload.to_json

        res = Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == 'https') do |http|
          http.request(req)
        end

        unless res.is_a?(Net::HTTPSuccess)
          raise APIError, "ActiveRabbit API request failed: #{res.code} #{res.body}"
        end

        JSON.parse(res.body)
      rescue => e
        @configuration.logger&.error("[ActiveRabbit] HTTP POST failed: #{e.class}: #{e.message}")
        nil
      end

      def test_connection
        response = make_request(:post, "/api/v1/test/connection", {
          gem_version: ActiveRabbit::Client::VERSION,
          timestamp: Time.now.iso8601
        })
        { success: true, data: response }
      rescue => e
        { success: false, error: e.message }
      end

      def flush
        return if @request_queue.empty?

        configuration.logger&.info("[ActiveRabbit] Starting flush with #{@request_queue.length} items")
        batch = @request_queue.shift(@request_queue.length)
        return if batch.empty?

        begin
          configuration.logger&.info("[ActiveRabbit] Sending batch of #{batch.length} items")
          response = post_batch(batch)
          configuration.logger&.info("[ActiveRabbit] Batch sent successfully: #{response.inspect}")
          response
        rescue => e
          configuration.logger&.error("[ActiveRabbit] Failed to send batch: #{e.message}")
          configuration.logger&.error("[ActiveRabbit] Backtrace: #{e.backtrace&.first(3)}")
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

        # Format data for batch processing
        formatted_data = {
          method: method,
          path: path,
          data: data,
          timestamp: Time.now.to_f
        }

        configuration.logger&.info("[ActiveRabbit] Enqueueing request: #{method} #{path}")
        configuration.logger&.debug("[ActiveRabbit] Request data: #{data.inspect}")

        @request_queue << formatted_data

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
        # Always rebuild base from current configuration to respect runtime changes
        current_base = URI(configuration.api_url)
        # Ensure path starts with a single leading slash
        normalized_path = path.start_with?("/") ? path : "/#{path}"
        uri = URI.join(current_base, normalized_path)
        configuration.logger&.info("[ActiveRabbit] Making request: #{method.upcase} #{uri}")
        configuration.logger&.debug("[ActiveRabbit] Request headers: X-Project-Token=#{configuration.api_key}, X-Project-ID=#{configuration.project_id}")
        configuration.logger&.debug("[ActiveRabbit] Request body: #{safe_preview(data)}")

        # Retry logic with exponential backoff
        retries = 0
        max_retries = configuration.retry_count

        begin
          response = perform_request(uri, method, data)
          configuration.logger&.info("[ActiveRabbit] Response status: #{response.code}")
          configuration.logger&.debug("[ActiveRabbit] Response headers: #{response.to_hash.inspect}")
          configuration.logger&.debug("[ActiveRabbit] Response body: #{response.body}")

          result = handle_response(response)
          configuration.logger&.debug("[ActiveRabbit] Parsed response: #{result.inspect}")
          result
        rescue RetryableError => e
          if retries < max_retries
            retries += 1
            configuration.logger&.info("[ActiveRabbit] Retrying request (#{retries}/#{max_retries})")
            sleep(configuration.retry_delay * (2 ** (retries - 1)))
            retry
          end
          raise APIError, e.message
        rescue Net::OpenTimeout, Net::ReadTimeout => e
          if retries < max_retries && should_retry_error?(e)
            retries += 1
            configuration.logger&.info("[ActiveRabbit] Retrying request after timeout (#{retries}/#{max_retries})")
            sleep(configuration.retry_delay * (2 ** (retries - 1))) # Exponential backoff
            retry
          end
          raise APIError, "Request timeout after #{retries} retries: #{e.message}"
        rescue Errno::ECONNREFUSED, Errno::EHOSTUNREACH, SocketError => e
          if retries < max_retries
            retries += 1
            configuration.logger&.info("[ActiveRabbit] Retrying request after connection error (#{retries}/#{max_retries})")
            sleep(configuration.retry_delay * (2 ** (retries - 1)))
            retry
          end
          raise APIError, "Connection failed after #{retries} retries: #{e.message}"
        rescue APIError, RateLimitError => e
          # Re-raise API errors as-is
          configuration.logger&.error("[ActiveRabbit] API error: #{e.class}: #{e.message}")
          raise e
        rescue => e
          configuration.logger&.error("[ActiveRabbit] Request failed: #{e.class}: #{e.message}")
          configuration.logger&.error("[ActiveRabbit] Backtrace: #{e.backtrace&.first(3)}")
          raise APIError, "Request failed: #{e.message}"
        end
      end

      def perform_request(uri, method, data)
        configuration.logger&.debug("[ActiveRabbit] Making HTTP request: #{method.upcase} #{uri}")
        http = Net::HTTP.new(uri.host, uri.port)

        # Configure SSL if HTTPS
        if uri.scheme == 'https'
          http.use_ssl = true
          http.verify_mode = OpenSSL::SSL::VERIFY_PEER
        end

        # Set timeouts
        http.open_timeout = configuration.open_timeout
        http.read_timeout = configuration.timeout

        # Create request with full path
        request = case method.to_s.downcase
                  when 'post'
                    Net::HTTP::Post.new(uri.request_uri)
                  when 'get'
                    Net::HTTP::Get.new(uri.request_uri)
                  when 'put'
                    Net::HTTP::Put.new(uri.request_uri)
                  when 'delete'
                    Net::HTTP::Delete.new(uri.request_uri)
                  else
                    raise ArgumentError, "Unsupported HTTP method: #{method}"
                  end

        configuration.logger&.debug("[ActiveRabbit] Request path: #{uri.request_uri}")

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
        configuration.logger&.debug("[ActiveRabbit] Response code: #{response.code}")
        configuration.logger&.debug("[ActiveRabbit] Response body: #{response.body}")

        case response.code.to_i
        when 200..299
          # Parse JSON response if present
          if response.body && !response.body.empty?
            begin
              parsed = JSON.parse(response.body)
              configuration.logger&.debug("[ActiveRabbit] Parsed response: #{parsed.inspect}")
              parsed
            rescue JSON::ParserError => e
              configuration.logger&.error("[ActiveRabbit] Failed to parse response: #{e.message}")
              configuration.logger&.error("[ActiveRabbit] Raw response: #{response.body}")
              response.body
            end
          else
            configuration.logger&.debug("[ActiveRabbit] Empty response body")
            {}
          end
        when 429
          configuration.logger&.error("[ActiveRabbit] Rate limit exceeded")
          raise RateLimitError, "Rate limit exceeded"
        when 400..499
          error_message = extract_error_message(response)
          configuration.logger&.error("[ActiveRabbit] Client error (#{response.code}): #{error_message}")
          raise APIError, "Client error (#{response.code}): #{error_message}"
        when 500..599
          error_message = extract_error_message(response)
          if should_retry_status?(response.code.to_i)
            configuration.logger&.warn("[ActiveRabbit] Retryable server error (#{response.code}): #{error_message}")
            raise RetryableError, "Server error (#{response.code}): #{error_message}"
          else
            configuration.logger&.error("[ActiveRabbit] Server error (#{response.code}): #{error_message}")
            raise APIError, "Server error (#{response.code}): #{error_message}"
          end
        else
          configuration.logger&.error("[ActiveRabbit] Unexpected response code: #{response.code}")
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

      def stringify_and_sanitize(obj, depth: 0)
        return nil if obj.nil?
        return obj if obj.is_a?(Numeric) || obj.is_a?(TrueClass) || obj.is_a?(FalseClass)
        return obj.to_s if obj.is_a?(Symbol) || obj.is_a?(Time) || obj.is_a?(Date) || obj.is_a?(URI) || obj.is_a?(Exception)

        if obj.is_a?(Hash)
          return obj.each_with_object({}) do |(k,v), h|
            # limit depth to avoid accidental deep object graphs
            h[k.to_s] = depth > 5 ? v.to_s : stringify_and_sanitize(v, depth: depth + 1)
          end
        end

        if obj.is_a?(Array)
          return obj.first(200).map { |v| depth > 5 ? v.to_s : stringify_and_sanitize(v, depth: depth + 1) }
        end

        # Fallback: best-effort string
        obj.to_s
      end

      def safe_preview(obj)
        # keep logs readable and safe
        s = obj.inspect
        s.length > 2000 ? s[0,2000] + "...(truncated)" : s
      end
    end

  end
end
