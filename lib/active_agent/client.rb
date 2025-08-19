# frozen_string_literal: true

require_relative "client/version"
require_relative "client/configuration"
require_relative "client/http_client"
require_relative "client/event_processor"
require_relative "client/exception_tracker"
require_relative "client/performance_monitor"
require_relative "client/n_plus_one_detector"
require_relative "client/pii_scrubber"

# Rails integration (optional)
begin
  require_relative "client/railtie" if defined?(Rails)
rescue LoadError
  # Rails not available, skip integration
end

# Sidekiq integration (optional)
begin
  require_relative "client/sidekiq_middleware" if defined?(Sidekiq)
rescue LoadError
  # Sidekiq not available, skip integration
end

module ActiveAgent
  module Client
    class Error < StandardError; end
    class ConfigurationError < Error; end
    class APIError < Error; end
    class RateLimitError < APIError; end

    class << self
      attr_accessor :configuration

      def configure
        self.configuration ||= Configuration.new
        yield(configuration) if block_given?
        configuration
      end

      def configured?
        return false unless configuration
        return false unless configuration.api_key
        return false if configuration.api_key.empty?
        true
      end

      # Event tracking methods
      def track_event(name, properties = {}, user_id: nil, timestamp: nil)
        return unless configured?

        event_processor.track_event(
          name: name,
          properties: properties,
          user_id: user_id,
          timestamp: timestamp || Time.now
        )
      end

      def track_exception(exception, context: {}, user_id: nil, tags: {})
        return unless configured?

        exception_tracker.track_exception(
          exception: exception,
          context: context,
          user_id: user_id,
          tags: tags
        )
      end

      def track_performance(name, duration_ms, metadata: {})
        return unless configured?

        performance_monitor.track_performance(
          name: name,
          duration_ms: duration_ms,
          metadata: metadata
        )
      end

      # Flush any pending events
      def flush
        return unless configured?

        event_processor.flush
        exception_tracker.flush
        performance_monitor.flush
      end

      # Shutdown the client gracefully
      def shutdown
        return unless configured?

        flush
        event_processor.shutdown
        http_client.shutdown
      end

      private

      def event_processor
        @event_processor ||= EventProcessor.new(configuration, http_client)
      end

      def exception_tracker
        @exception_tracker ||= ExceptionTracker.new(configuration, http_client)
      end

      def performance_monitor
        @performance_monitor ||= PerformanceMonitor.new(configuration, http_client)
      end

      def http_client
        @http_client ||= HttpClient.new(configuration)
      end
    end
  end
end
