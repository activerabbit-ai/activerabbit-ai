# frozen_string_literal: true

begin
  require "rails/railtie"
rescue LoadError
  # Rails not available, define minimal structure for testing
  module Rails
    class Railtie; end
  end
end

require "securerandom"

module ActiveRabbit
  module Client
    class Railtie < Rails::Railtie
      config.active_rabbit = ActiveSupport::OrderedOptions.new

      initializer "active_rabbit.configure" do |app|
        # Configure ActiveRabbit from Rails configuration
        ActiveRabbit::Client.configure do |config|
          config.environment = Rails.env
          config.logger = Rails.logger
          config.release = detect_release(app)
        end

        # Set up exception tracking
        setup_exception_tracking(app) if ActiveRabbit::Client.configured?
      end

      initializer "active_rabbit.subscribe_to_notifications" do
        next unless ActiveRabbit::Client.configured?

        # Subscribe to Action Controller events
        subscribe_to_controller_events

        # Subscribe to Active Record events
        subscribe_to_active_record_events

        # Subscribe to Action View events
        subscribe_to_action_view_events

        # Subscribe to Action Mailer events (if available)
        subscribe_to_action_mailer_events if defined?(ActionMailer)

        # Subscribe to exception notifications
        subscribe_to_exception_notifications
      end

      initializer "active_rabbit.add_middleware" do |app|
        next unless ActiveRabbit::Client.configured?

        # Add request context middleware
        app.middleware.insert_before ActionDispatch::ShowExceptions, RequestContextMiddleware

        # Add exception catching middleware
        app.middleware.insert_before ActionDispatch::ShowExceptions, ExceptionMiddleware
      end

      initializer "active_rabbit.setup_shutdown_hooks" do
        next unless ActiveRabbit::Client.configured?

        # Ensure we flush pending data on shutdown
        at_exit do
          begin
            ActiveRabbit::Client.flush
          rescue => e
            # Don't let shutdown hooks fail the process
            Rails.logger.error "[ActiveRabbit] Error during shutdown flush: #{e.message}" if defined?(Rails)
          end
        end

        # Also flush on SIGTERM (common in production deployments)
        if Signal.list.include?('TERM')
          Signal.trap('TERM') do
            begin
              ActiveRabbit::Client.flush
            rescue => e
              # Log but don't raise
              Rails.logger.error "[ActiveRabbit] Error during SIGTERM flush: #{e.message}" if defined?(Rails)
            end
            # Continue with normal SIGTERM handling
            exit(0)
          end
        end
      end

      private

      def setup_exception_tracking(app)
        # Handle uncaught exceptions in development
        if Rails.env.development? || Rails.env.test?
          app.config.consider_all_requests_local = false if Rails.env.test?
        end
      end

      def subscribe_to_controller_events
        ActiveSupport::Notifications.subscribe "process_action.action_controller" do |name, started, finished, unique_id, payload|
          begin
            duration_ms = ((finished - started) * 1000).round(2)

            ActiveRabbit::Client.track_performance(
              "controller.action",
              duration_ms,
              metadata: {
                controller: payload[:controller],
                action: payload[:action],
                format: payload[:format],
                method: payload[:method],
                path: payload[:path],
                status: payload[:status],
                view_runtime: payload[:view_runtime],
                db_runtime: payload[:db_runtime]
              }
            )

            # Track slow requests
            if duration_ms > 1000 # Slower than 1 second
              ActiveRabbit::Client.track_event(
                "slow_request",
                {
                  controller: payload[:controller],
                  action: payload[:action],
                  duration_ms: duration_ms,
                  method: payload[:method],
                  path: payload[:path]
                }
              )
            end
          rescue => e
            Rails.logger.error "[ActiveRabbit] Error tracking controller action: #{e.message}"
          end
        end
      end

      def subscribe_to_active_record_events
        # Track database queries for N+1 detection
        ActiveSupport::Notifications.subscribe "sql.active_record" do |name, started, finished, unique_id, payload|
          begin
            next if payload[:name] == "SCHEMA" || payload[:name] == "CACHE"

            duration_ms = ((finished - started) * 1000).round(2)

            # Track query for N+1 detection
            if ActiveRabbit::Client.configuration.enable_n_plus_one_detection
              n_plus_one_detector.track_query(
                payload[:sql],
                payload[:bindings],
                payload[:name],
                duration_ms
              )
            end

            # Track slow queries
            if duration_ms > 100 # Slower than 100ms
              ActiveRabbit::Client.track_event(
                "slow_query",
                {
                  sql: payload[:sql],
                  duration_ms: duration_ms,
                  name: payload[:name]
                }
              )
            end
          rescue => e
            Rails.logger.error "[ActiveRabbit] Error tracking SQL query: #{e.message}"
          end
        end
      end

      def subscribe_to_action_view_events
        ActiveSupport::Notifications.subscribe "render_template.action_view" do |name, started, finished, unique_id, payload|
          begin
            duration_ms = ((finished - started) * 1000).round(2)

            # Track slow template renders
            if duration_ms > 50 # Slower than 50ms
              ActiveRabbit::Client.track_event(
                "slow_template_render",
                {
                  template: payload[:identifier],
                  duration_ms: duration_ms,
                  layout: payload[:layout]
                }
              )
            end
          rescue => e
            Rails.logger.error "[ActiveRabbit] Error tracking template render: #{e.message}"
          end
        end
      end

      def subscribe_to_action_mailer_events
        ActiveSupport::Notifications.subscribe "deliver.action_mailer" do |name, started, finished, unique_id, payload|
          begin
            duration_ms = ((finished - started) * 1000).round(2)

            ActiveRabbit::Client.track_event(
              "email_sent",
              {
                mailer: payload[:mailer],
                action: payload[:action],
                duration_ms: duration_ms
              }
            )
          rescue => e
            Rails.logger.error "[ActiveRabbit] Error tracking email delivery: #{e.message}"
          end
        end
      end

      def subscribe_to_exception_notifications
        # Subscribe to Rails exception notifications for rescued exceptions
        ActiveSupport::Notifications.subscribe "process_action.action_controller" do |name, started, finished, unique_id, data|
          next unless ActiveRabbit::Client.configured?

          # Check for rescued exceptions in the payload
          exception = nil
          if data[:exception_object]
            # Rails 7+ provides the actual exception object
            exception = data[:exception_object]
          elsif data[:exception]
            # Fallback: reconstruct exception from class name and message
            exception_class_name, exception_message = data[:exception]
            begin
              exception_class = exception_class_name.constantize
              exception = exception_class.new(exception_message)
            rescue NameError
              # If we can't constantize the exception class, create a generic one
              exception = StandardError.new("#{exception_class_name}: #{exception_message}")
            end
          end

          next unless exception

          ActiveRabbit::Client.track_exception(
            exception,
            context: {
              request: {
                method: data[:method],
                path: data[:path],
                controller: data[:controller],
                action: data[:action],
                status: data[:status],
                format: data[:format],
                params: scrub_sensitive_params(data[:params])
              },
              timing: {
                duration_ms: ((finished - started) * 1000).round(2),
                view_runtime: data[:view_runtime],
                db_runtime: data[:db_runtime]
              }
            }
          )
        end
      end

      def detect_release(app)
        # Try to detect release from various sources
        ENV["HEROKU_SLUG_COMMIT"] ||
          ENV["GITHUB_SHA"] ||
          ENV["GITLAB_COMMIT_SHA"] ||
          app.config.active_rabbit.release ||
          detect_git_sha
      end

      def detect_git_sha
        return unless Rails.root.join(".git").directory?

        `git rev-parse HEAD 2>/dev/null`.chomp
      rescue
        nil
      end

      def scrub_sensitive_params(params)
        return {} unless params
        return params unless ActiveRabbit::Client.configuration.enable_pii_scrubbing

        PiiScrubber.new(ActiveRabbit::Client.configuration).scrub(params)
      end

      def n_plus_one_detector
        @n_plus_one_detector ||= NPlusOneDetector.new(ActiveRabbit::Client.configuration)
      end
    end

    # Middleware for adding request context
    class RequestContextMiddleware
      def initialize(app)
        @app = app
      end

      def call(env)
        request = ActionDispatch::Request.new(env)

        # Skip certain requests
        return @app.call(env) if should_skip_request?(request)

        # Set request context
        request_context = build_request_context(request)
        request_id = SecureRandom.uuid

        # Store previous context to restore later (in case of nested requests)
        previous_context = Thread.current[:active_rabbit_request_context]
        Thread.current[:active_rabbit_request_context] = request_context

        # Start N+1 detection for this request
        n_plus_one_detector.start_request(request_id)

        begin
          @app.call(env)
        ensure
          # Always clean up request context, even if an exception occurred
          begin
            n_plus_one_detector.finish_request(request_id)
          rescue => e
            # Log but don't raise - we don't want cleanup to fail the request
            Rails.logger.error "[ActiveRabbit] Error finishing N+1 detection: #{e.message}" if defined?(Rails)
          end

          # Restore previous context (handles nested requests)
          Thread.current[:active_rabbit_request_context] = previous_context
        end
      end

      private

      def should_skip_request?(request)
        # Skip requests from ignored user agents
        user_agent = request.headers["User-Agent"]
        return true if ActiveRabbit::Client.configuration.should_ignore_user_agent?(user_agent)

        # Skip asset requests
        return true if request.path.start_with?("/assets/")

        # Skip health checks
        return true if request.path.match?(/\/(health|ping|status)/)

        false
      end

      def build_request_context(request)
        {
          method: request.method,
          path: request.path,
          query_string: request.query_string,
          user_agent: request.headers["User-Agent"],
          ip_address: request.remote_ip,
          referer: request.referer,
          request_id: request.headers["X-Request-ID"] || SecureRandom.uuid
        }
      end

      def n_plus_one_detector
        @n_plus_one_detector ||= NPlusOneDetector.new(ActiveRabbit::Client.configuration)
      end
    end

    # Middleware for catching unhandled exceptions
    class ExceptionMiddleware
      def initialize(app)
        @app = app
      end

      def call(env)
        @app.call(env)
      rescue Exception => exception
        # Track the exception, but don't let tracking errors break the request
        begin
          request = ActionDispatch::Request.new(env)

          ActiveRabbit::Client.track_exception(
            exception,
            context: {
              request: {
                method: request.method,
                path: request.path,
                query_string: request.query_string,
                user_agent: request.headers["User-Agent"],
                ip_address: request.remote_ip,
                referer: request.referer,
                headers: sanitize_headers(request.headers)
              },
              middleware: {
                caught_by: 'ExceptionMiddleware',
                timestamp: Time.now.iso8601(3)
              }
            }
          )
        rescue => tracking_error
          # Log tracking errors but don't let them interfere with exception handling
          Rails.logger.error "[ActiveRabbit] Error tracking exception: #{tracking_error.message}" if defined?(Rails)
        end

        # Re-raise the original exception so Rails can handle it normally
        raise exception
      end

      private

      def sanitize_headers(headers)
        # Only include safe headers to avoid PII
        safe_headers = {}
        headers.each do |key, value|
          next unless key.is_a?(String)

          # Include common safe headers
          if key.match?(/^(HTTP_ACCEPT|HTTP_ACCEPT_ENCODING|HTTP_ACCEPT_LANGUAGE|HTTP_CACHE_CONTROL|HTTP_CONNECTION|HTTP_HOST|HTTP_UPGRADE_INSECURE_REQUESTS|HTTP_USER_AGENT|CONTENT_TYPE|REQUEST_METHOD|REQUEST_URI|SERVER_NAME|SERVER_PORT)$/i)
            safe_headers[key] = value
          end
        end
        safe_headers
      end
    end
  end
end
