# frozen_string_literal: true

require "rails/railtie"
require "securerandom"

module ActiveAgent
  module Client
    class Railtie < Rails::Railtie
      config.active_agent = ActiveSupport::OrderedOptions.new

      initializer "active_agent.configure" do |app|
        # Configure ActiveAgent from Rails configuration
        ActiveAgent::Client.configure do |config|
          config.environment = Rails.env
          config.logger = Rails.logger
          config.release = detect_release(app)
        end

        # Set up exception tracking
        setup_exception_tracking(app) if ActiveAgent::Client.configured?
      end

      initializer "active_agent.subscribe_to_notifications" do
        next unless ActiveAgent::Client.configured?

        # Subscribe to Action Controller events
        subscribe_to_controller_events

        # Subscribe to Active Record events
        subscribe_to_active_record_events

        # Subscribe to Action View events
        subscribe_to_action_view_events

        # Subscribe to Action Mailer events (if available)
        subscribe_to_action_mailer_events if defined?(ActionMailer)
      end

      initializer "active_agent.add_middleware" do |app|
        next unless ActiveAgent::Client.configured?

        # Add request context middleware
        app.middleware.insert_before ActionDispatch::ShowExceptions, RequestContextMiddleware

        # Add exception catching middleware
        app.middleware.insert_before ActionDispatch::ShowExceptions, ExceptionMiddleware
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

            ActiveAgent::Client.track_performance(
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
              ActiveAgent::Client.track_event(
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
            Rails.logger.error "[ActiveAgent] Error tracking controller action: #{e.message}"
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
            if ActiveAgent::Client.configuration.enable_n_plus_one_detection
              n_plus_one_detector.track_query(
                payload[:sql],
                payload[:bindings],
                payload[:name],
                duration_ms
              )
            end

            # Track slow queries
            if duration_ms > 100 # Slower than 100ms
              ActiveAgent::Client.track_event(
                "slow_query",
                {
                  sql: payload[:sql],
                  duration_ms: duration_ms,
                  name: payload[:name]
                }
              )
            end
          rescue => e
            Rails.logger.error "[ActiveAgent] Error tracking SQL query: #{e.message}"
          end
        end
      end

      def subscribe_to_action_view_events
        ActiveSupport::Notifications.subscribe "render_template.action_view" do |name, started, finished, unique_id, payload|
          begin
            duration_ms = ((finished - started) * 1000).round(2)

            # Track slow template renders
            if duration_ms > 50 # Slower than 50ms
              ActiveAgent::Client.track_event(
                "slow_template_render",
                {
                  template: payload[:identifier],
                  duration_ms: duration_ms,
                  layout: payload[:layout]
                }
              )
            end
          rescue => e
            Rails.logger.error "[ActiveAgent] Error tracking template render: #{e.message}"
          end
        end
      end

      def subscribe_to_action_mailer_events
        ActiveSupport::Notifications.subscribe "deliver.action_mailer" do |name, started, finished, unique_id, payload|
          begin
            duration_ms = ((finished - started) * 1000).round(2)

            ActiveAgent::Client.track_event(
              "email_sent",
              {
                mailer: payload[:mailer],
                action: payload[:action],
                duration_ms: duration_ms
              }
            )
          rescue => e
            Rails.logger.error "[ActiveAgent] Error tracking email delivery: #{e.message}"
          end
        end
      end

      def detect_release(app)
        # Try to detect release from various sources
        ENV["HEROKU_SLUG_COMMIT"] ||
          ENV["GITHUB_SHA"] ||
          ENV["GITLAB_COMMIT_SHA"] ||
          app.config.active_agent.release ||
          detect_git_sha
      end

      def detect_git_sha
        return unless Rails.root.join(".git").directory?

        `git rev-parse HEAD 2>/dev/null`.chomp
      rescue
        nil
      end

      def n_plus_one_detector
        @n_plus_one_detector ||= NPlusOneDetector.new(ActiveAgent::Client.configuration)
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
        Thread.current[:active_agent_request_context] = request_context

        # Start N+1 detection for this request
        request_id = SecureRandom.uuid
        n_plus_one_detector.start_request(request_id)

        begin
          @app.call(env)
        ensure
          # Clean up request context
          Thread.current[:active_agent_request_context] = nil
          n_plus_one_detector.finish_request(request_id)
        end
      end

      private

      def should_skip_request?(request)
        # Skip requests from ignored user agents
        user_agent = request.headers["User-Agent"]
        return true if ActiveAgent::Client.configuration.should_ignore_user_agent?(user_agent)

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
        @n_plus_one_detector ||= NPlusOneDetector.new(ActiveAgent::Client.configuration)
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
        # Track the exception
        request = ActionDispatch::Request.new(env)

        ActiveAgent::Client.track_exception(
          exception,
          context: {
            request: {
              method: request.method,
              path: request.path,
              query_string: request.query_string,
              user_agent: request.headers["User-Agent"],
              ip_address: request.remote_ip,
              referer: request.referer
            }
          }
        )

        # Re-raise the exception so Rails can handle it normally
        raise exception
      end
    end
  end
end
