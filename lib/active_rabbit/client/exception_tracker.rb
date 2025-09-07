# frozen_string_literal: true

require "digest"
require "time"

module ActiveRabbit
  module Client
    class ExceptionTracker
      attr_reader :configuration, :http_client

      def initialize(configuration, http_client)
        @configuration = configuration
        @http_client = http_client
      end

      def track_exception(exception:, context: {}, user_id: nil, tags: {}, handled: nil, force: false)
        return unless exception
        return if !force && should_ignore_exception?(exception)

        exception_data = build_exception_data(
          exception: exception,
          context: context,
          user_id: user_id,
          tags: tags,
          handled: handled
        )

        # Apply before_send callback if configured
        if configuration.before_send_exception
          exception_data = configuration.before_send_exception.call(exception_data)
          return unless exception_data # Callback can filter out exceptions by returning nil
        end

        # Send exception to API and return response
        configuration.logger&.info("[ActiveRabbit] Preparing to send exception: #{exception.class.name}")
        configuration.logger&.debug("[ActiveRabbit] Exception data: #{exception_data.inspect}")

        # Ensure we have required fields
        unless exception_data[:exception_class] && exception_data[:message] && exception_data[:backtrace]
          configuration.logger&.error("[ActiveRabbit] Missing required fields in exception data")
          configuration.logger&.debug("[ActiveRabbit] Available fields: #{exception_data.keys.inspect}")
          return nil
        end

        response = http_client.post_exception(exception_data)

        if response.nil?
          configuration.logger&.error("[ActiveRabbit] Failed to send exception - both primary and fallback endpoints failed")
          return nil
        end

        configuration.logger&.info("[ActiveRabbit] Exception successfully sent to API")
        configuration.logger&.debug("[ActiveRabbit] API Response: #{response.inspect}")
        response
      end

      def flush
        # Exception tracker sends immediately, no batching needed
      end

      private

      def build_exception_data(exception:, context:, user_id:, tags:, handled: nil)
        parsed_bt = parse_backtrace(exception.backtrace || [])
        backtrace_lines = parsed_bt.map { |frame| frame[:line] }

        # Fallback: synthesize a helpful frame for routing errors with no backtrace
        if backtrace_lines.empty?
          synthetic = nil
          if context && (context[:routing]&.[](:path) || context[:request_path])
            path = context[:routing]&.[](:path) || context[:request_path]
            synthetic = "#{defined?(Rails) && Rails.respond_to?(:root) ? Rails.root : 'app'}/config/routes.rb:1:in `route_not_found' for #{path}"
          elsif exception && exception.message && exception.message =~ /No route matches \[(\w+)\] \"(.+?)\"/
            path = $2
            synthetic = "#{defined?(Rails) && Rails.respond_to?(:root) ? Rails.root : 'app'}/config/routes.rb:1:in `route_not_found' for #{path}"
          end
          backtrace_lines = [synthetic] if synthetic
        end

        # Build data in the format the API expects
        data = {
          # Required fields
          exception_class: exception.class.name,
          message: exception.message,
          backtrace: backtrace_lines,

          # Timing and environment
          occurred_at: Time.now.iso8601(3),
          environment: configuration.environment || 'development',
          release_version: configuration.release,
          server_name: configuration.server_name,

          # Context from the error
          controller_action: context[:controller_action],
          request_path: context[:request_path],
          request_method: context[:request_method],

          # Additional context
          context: scrub_pii(context || {}),
          tags: tags || {},
          user_id: user_id,
          project_id: configuration.project_id,

          # Runtime info
          runtime_context: build_runtime_context,

          # Error details (for better UI display)
          error_type: context[:error_type] || exception.class.name,
          error_message: context[:error_message] || exception.message,
          error_location: context[:error_location] || backtrace_lines.first,
          error_severity: context[:error_severity] || :error,
          error_status: context[:error_status] || 500,
          error_source: context[:error_source] || 'Application',
          error_component: context[:error_component] || 'Unknown',
          error_action: context[:error_action],
          handled: context.key?(:handled) ? context[:handled] : handled,

          # Request details
          request_details: context[:request_details],
          response_time: context[:response_time],
          routing_info: context[:routing_info]
        }

        # Add request context if available
        if defined?(Thread) && Thread.current[:active_rabbit_request_context]
          data[:request_context] = Thread.current[:active_rabbit_request_context]
        end

        # Add background job context if available
        if defined?(Thread) && Thread.current[:active_rabbit_job_context]
          data[:job_context] = Thread.current[:active_rabbit_job_context]
        end

        # Log what we're sending
        configuration.logger&.debug("[ActiveRabbit] Built exception data:")
        configuration.logger&.debug("[ActiveRabbit] - Required fields: class=#{data[:exception_class]}, message=#{data[:message]}, backtrace=#{data[:backtrace]&.first}")
        configuration.logger&.debug("[ActiveRabbit] - Error details: type=#{data[:error_type]}, source=#{data[:error_source]}, component=#{data[:error_component]}")
        configuration.logger&.debug("[ActiveRabbit] - Request info: path=#{data[:request_path]}, method=#{data[:request_method]}, action=#{data[:controller_action]}")

        data
      end

      def parse_backtrace(backtrace)
        backtrace.map do |line|
          if match = line.match(/^(.+?):(\d+)(?::in `(.+?)')?$/)
            {
              filename: match[1],
              lineno: match[2].to_i,
              method: match[3],
              line: line
            }
          else
            { line: line }
          end
        end
      end

      def generate_fingerprint(exception)
        # Create a consistent fingerprint for grouping similar exceptions
        parts = [
          exception.class.name,
          clean_message_for_fingerprint(exception.message),
          extract_relevant_backtrace_for_fingerprint(exception.backtrace)
        ].compact

        Digest::SHA256.hexdigest(parts.join("|"))
      end

      def clean_message_for_fingerprint(message)
        return "" unless message

        # Remove dynamic content that would prevent proper grouping
        message
          .gsub(/\d+/, "N") # Replace numbers with N
          .gsub(/0x[a-f0-9]+/i, "0xHEX") # Replace hex addresses
          .gsub(/'[^']+'/, "'STRING'") # Replace quoted strings
          .gsub(/"[^"]+"/, '"STRING"') # Replace double-quoted strings
          .gsub(/\/[^\/\s]+\/[^\/\s]*/, "/PATH/") # Replace file paths
      end

      def extract_relevant_backtrace_for_fingerprint(backtrace)
        return "" unless backtrace

        # Take the first few frames from the application (not gems/stdlib)
        app_frames = backtrace
          .select { |line| line.include?(Dir.pwd) } # Only app files
          .first(3) # First 3 frames
          .map { |line| line.gsub(/:\d+/, ":LINE") } # Remove line numbers

        app_frames.join("|")
      end

      def build_runtime_context
        context = {
          ruby_version: RUBY_VERSION,
          ruby_platform: RUBY_PLATFORM,
          gem_version: VERSION
        }

        # Add framework information
        if defined?(Rails)
          context[:rails_version] = Rails.version
          context[:rails_env] = Rails.env if Rails.respond_to?(:env)
        end

        # Add memory usage if available
        begin
          if defined?(GC)
            context[:gc_stats] = GC.stat
          end
        rescue
          # Ignore if GC.stat is not available
        end

        context
      end

      def should_ignore_exception?(exception)
        configuration.should_ignore_exception?(exception)
      end

      def scrub_pii(data)
        return data unless configuration.enable_pii_scrubbing

        PiiScrubber.new(configuration).scrub(data)
      end
    end
  end
end
