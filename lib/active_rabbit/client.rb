# frozen_string_literal: true

require_relative "client/version"
require_relative "client/configuration"
require_relative "client/http_client"
require_relative "client/event_processor"
require_relative "client/exception_tracker"
require_relative "client/performance_monitor"
require_relative "client/n_plus_one_detector"
require_relative "client/pii_scrubber"
require_relative "client/error_reporter"

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

module ActiveRabbit
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

      def track_exception(exception, context: {}, user_id: nil, tags: {}, handled: nil, force: false)
        return unless configured?

        context_with_tags = context

        # Track the exception
        args = {
          exception: exception,
          context: context_with_tags,
          user_id: user_id,
          tags: tags
        }
        args[:handled] = handled unless handled.nil?
        args[:force] = true if force

        result = exception_tracker.track_exception(**args)

        # Log the result
        ActiveRabbit::Client.log(:info, "[ActiveRabbit] Exception tracked: #{exception.class.name}")
        ActiveRabbit::Client.log(:debug, "[ActiveRabbit] Exception tracking result: #{result.inspect}")

        result
      end

      def track_performance(name, duration_ms, metadata: {})
        return unless configured?

        performance_monitor.track_performance(
          name: name,
          duration_ms: duration_ms,
          metadata: metadata
        )
      end

      # Test connection to ActiveRabbit API
      def test_connection
        return { success: false, error: "ActiveRabbit not configured" } unless configured?

        begin
          http_client.test_connection
        rescue => e
          { success: false, error: e.message }
        end
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

      # Manual capture convenience for non-Rails contexts
      def capture_exception(exception, context: {}, user_id: nil, tags: {})
        track_exception(exception, context: context, user_id: user_id, tags: tags)
      end

      def notify_deploy(project_slug:, status:, user:, version:, started_at: nil, finished_at: nil)
        payload = {
          revision: Client.configuration.revision,
          environment: Client.configuration.environment,
          project_slug: project_slug,
          version: version,
          status: status,
          user: user,
          started_at: started_at,
          finished_at: finished_at
        }

        http_client.post("/api/v1/deploys", payload)
      end

      # Ping ActiveRabbit that a new version (release/revision) is deployed.
      #
      # This is intended to be called from a deploy hook or automatically after Rails boots
      # when `config.auto_release_tracking` is enabled.
      #
      # The API treats duplicates as conflict (409); the client treats that as success.
      def notify_release(version: nil, environment: nil, metadata: {})
        return unless configured?

        cfg = configuration
        version ||= cfg.revision || cfg.release
        environment ||= cfg.environment
        return if version.nil? || version.to_s.strip.empty?

        payload = {
          version: version,
          environment: environment,
          metadata: metadata || {}
        }

        http_client.post_release(payload)
      end

      def log(level, message)
        cfg = configuration
        return if cfg.nil? || cfg.disable_console_logs

        case level
        when :info  then cfg.logger&.info(message)
        when :debug then cfg.logger&.debug(message)
        when :error then cfg.logger&.error(message)
        end
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
