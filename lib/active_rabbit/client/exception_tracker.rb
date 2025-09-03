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

      def track_exception(exception:, context: {}, user_id: nil, tags: {})
        return unless exception
        return if should_ignore_exception?(exception)

        exception_data = build_exception_data(
          exception: exception,
          context: context,
          user_id: user_id,
          tags: tags
        )

        # Apply before_send callback if configured
        if configuration.before_send_exception
          exception_data = configuration.before_send_exception.call(exception_data)
          return unless exception_data # Callback can filter out exceptions by returning nil
        end

        http_client.post_exception(exception_data)
      end

      def flush
        # Exception tracker sends immediately, no batching needed
      end

      private

      def build_exception_data(exception:, context:, user_id:, tags:)
        backtrace = parse_backtrace(exception.backtrace || [])

        data = {
          type: exception.class.name,
          message: exception.message,
          backtrace: backtrace,
          fingerprint: generate_fingerprint(exception),
          timestamp: Time.now.iso8601(3),
          environment: configuration.environment,
          release: configuration.release,
          server_name: configuration.server_name,
          context: scrub_pii(context || {}),
          tags: tags || {}
        }

        data[:user_id] = user_id if user_id
        data[:project_id] = configuration.project_id if configuration.project_id

        # Add runtime context
        data[:runtime_context] = build_runtime_context

        # Add request context if available
        if defined?(Thread) && Thread.current[:active_rabbit_request_context]
          data[:request_context] = Thread.current[:active_rabbit_request_context]
        end

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
