# frozen_string_literal: true

require "logger"

begin
  require "rails/railtie"
rescue LoadError
  # Rails not available, define minimal structure for testing
  module Rails
    class Railtie; end
  end
end

require "securerandom"
require_relative "../reporting"
require_relative "../middleware/error_capture_middleware"

module ActiveRabbit
  module Client
    class Railtie < Rails::Railtie
      config.active_rabbit = ActiveSupport::OrderedOptions.new

      initializer "active_rabbit.configure", after: :initialize_logger do |app|
        apply_rails_configuration(app.config.active_rabbit)

        if ActiveRabbit::Client.configuration && !ActiveRabbit::Client.configuration.disable_console_logs
          if Rails.env.development?
            ar_puts "\n=== ActiveRabbit Configure ==="
            ar_puts "Environment: #{Rails.env}"
            ar_puts "Already configured? #{ActiveRabbit::Client.configured?}"
            ar_puts "================================\n"
          end
        end

        # Configure ActiveRabbit from Rails configuration
        ActiveRabbit::Client.configure do |config|
          config.environment ||= Rails.env
          config.logger ||= Rails.logger rescue Logger.new(STDOUT)
          config.release ||= detect_release(app)
        end

        # if ActiveRabbit::Client.configuration && !ActiveRabbit::Client.configuration.disable_console_logs
        #   if Rails.env.development?
        #     ar_puts "\n=== ActiveRabbit Post-Configure ==="
        #     ar_puts "Now configured? #{ActiveRabbit::Client.configured?}"
        #     ar_puts "Configuration: #{ActiveRabbit::Client.configuration.inspect}"
        #     ar_puts "================================\n"
        #   end
        # end

        # Set up exception tracking
        setup_exception_tracking(app) if ActiveRabbit::Client.configured?
      end

      initializer "active_rabbit.subscribe_to_notifications", after: :load_config_initializers do |app|
        ar_log(:info, "[ActiveRabbit] Setting up performance notifications subscriptions")
        # Subscribe regardless; each handler guards on configured?
        subscribe_to_controller_events
        subscribe_to_active_record_events
        subscribe_to_action_view_events
        subscribe_to_action_mailer_events if defined?(ActionMailer)
        subscribe_to_exception_notifications
        ar_log(:info, "[ActiveRabbit] Subscriptions setup complete")

        # Defer complex subscriptions until after initialization
        app.config.after_initialize do

          # DISABLED: rack.exception creates duplicate events because middleware already catches all errors
          # The middleware is the primary error capture mechanism and catches errors at the optimal level
          # ActiveSupport::Notifications.subscribe("rack.exception") do |*args|
          #   begin
          #     payload = args.last
          #     exception = payload[:exception_object]
          #     env = payload[:env]
          #     next unless exception
          #
          #     ActiveRabbit::Reporting.report_exception(
          #       exception,
          #       env: env,
          #       handled: false,
          #       source: "rack.exception",
          #       force: true
          #     )
          #   rescue => e
          #     Rails.logger.error "[ActiveRabbit] Error handling rack.exception: #{e.class}: #{e.message}" if defined?(Rails)
          #   end
          # end
        end
      end

      # Configure middleware after logger is initialized to avoid init cycles
      initializer "active_rabbit.add_middleware", after: :initialize_logger do |app|
        if Rails.env.development?
          ar_puts "\n=== ActiveRabbit Railtie Loading ==="
          ar_puts "Rails Environment: #{Rails.env}"
          ar_puts "Rails Middleware Stack Phase: #{app.middleware.respond_to?(:middlewares) ? 'Ready' : 'Not Ready'}"
          ar_puts "================================\n"
          ar_puts "\n=== Initial Middleware Stack ==="
          ar_puts "(not available at this boot phase)"
          ar_puts "=======================\n"
        end

        ar_puts "\n=== Adding ActiveRabbit Middleware ===" if Rails.env.development?
        # Handle both development (DebugExceptions) and production (ShowExceptions)
        if defined?(ActionDispatch::DebugExceptions)
          ar_puts "[ActiveRabbit] Found DebugExceptions, configuring middleware..." if Rails.env.development?

          # First remove any existing middleware to avoid duplicates
          begin
            app.config.middleware.delete(ActiveRabbit::Client::ExceptionMiddleware)
            app.config.middleware.delete(ActiveRabbit::Client::RequestContextMiddleware)
            app.config.middleware.delete(ActiveRabbit::Client::RoutingErrorCatcher)
            ar_puts "[ActiveRabbit] Cleaned up existing middleware" if Rails.env.development?
          rescue => e
            ar_puts "[ActiveRabbit] Error cleaning middleware: #{e.message}"
          end

          # Insert middleware in the correct order
          ar_puts "[ActiveRabbit] Inserting middleware..." if Rails.env.development?

          # Insert ErrorCaptureMiddleware after DebugExceptions to rely on rescue path
          app.config.middleware.insert_after(ActionDispatch::DebugExceptions, ActiveRabbit::Middleware::ErrorCaptureMiddleware)

          # Insert RequestContextMiddleware early in the stack
          ar_puts "[ActiveRabbit] Inserting RequestContextMiddleware before RequestId" if Rails.env.development?
          app.config.middleware.insert_before(ActionDispatch::RequestId, ActiveRabbit::Client::RequestContextMiddleware)

          # Insert ExceptionMiddleware before Rails' exception handlers (kept for env-based reporting)
          ar_puts "[ActiveRabbit] Inserting ExceptionMiddleware before DebugExceptions" if Rails.env.development?
          app.config.middleware.insert_before(ActionDispatch::DebugExceptions, ActiveRabbit::Client::ExceptionMiddleware)

          # Insert RoutingErrorCatcher after Rails' exception handlers
          ar_puts "[ActiveRabbit] Inserting RoutingErrorCatcher after DebugExceptions" if Rails.env.development?
          app.config.middleware.insert_after(ActionDispatch::DebugExceptions, ActiveRabbit::Client::RoutingErrorCatcher)

          ar_puts "[ActiveRabbit] Middleware insertion complete" if Rails.env.development?

        elsif defined?(ActionDispatch::ShowExceptions)
          ar_puts "[ActiveRabbit] Found ShowExceptions, configuring middleware..." if Rails.env.development?

          # First remove any existing middleware to avoid duplicates
          begin
            app.config.middleware.delete(ActiveRabbit::Client::ExceptionMiddleware)
            app.config.middleware.delete(ActiveRabbit::Client::RequestContextMiddleware)
            app.config.middleware.delete(ActiveRabbit::Client::RoutingErrorCatcher)
            ar_puts "[ActiveRabbit] Cleaned up existing middleware" if Rails.env.development?
          rescue => e
            ar_puts "[ActiveRabbit] Error cleaning middleware: #{e.message}"
          end

          # Insert middleware in the correct order
          ar_puts "[ActiveRabbit] Inserting middleware..." if Rails.env.development?

          # Insert ErrorCaptureMiddleware after ShowExceptions
          app.config.middleware.insert_after(ActionDispatch::ShowExceptions, ActiveRabbit::Middleware::ErrorCaptureMiddleware)

          # Insert RequestContextMiddleware early in the stack
          ar_puts "[ActiveRabbit] Inserting RequestContextMiddleware before RequestId" if Rails.env.development?
          app.config.middleware.insert_before(ActionDispatch::RequestId, ActiveRabbit::Client::RequestContextMiddleware)

          # Insert ExceptionMiddleware before Rails' exception handlers
          ar_puts "[ActiveRabbit] Inserting ExceptionMiddleware before ShowExceptions" if Rails.env.development?
          app.config.middleware.insert_before(ActionDispatch::ShowExceptions, ActiveRabbit::Client::ExceptionMiddleware)

          # Insert RoutingErrorCatcher after Rails' exception handlers
          ar_puts "[ActiveRabbit] Inserting RoutingErrorCatcher after ShowExceptions" if Rails.env.development?
          app.config.middleware.insert_after(ActionDispatch::ShowExceptions, ActiveRabbit::Client::RoutingErrorCatcher)

        else
          ar_puts "[ActiveRabbit] No exception handlers found, using fallback configuration" if Rails.env.development?
          app.config.middleware.use(ActiveRabbit::Middleware::ErrorCaptureMiddleware)
          app.config.middleware.use(ActiveRabbit::Client::RequestContextMiddleware)
          app.config.middleware.use(ActiveRabbit::Client::ExceptionMiddleware)
          app.config.middleware.use(ActiveRabbit::Client::RoutingErrorCatcher)
        end

        if Rails.env.development?
          ar_puts "\n=== Final Middleware Stack ==="
          ar_puts "(will be printed after initialize)"
          ar_puts "=======================\n"
        end

          # Add debug wrappers in development
        if Rails.env.development?
          # Wrap ExceptionMiddleware for detailed error tracking
          ActiveRabbit::Client::ExceptionMiddleware.class_eval do
            alias_method :__ar_original_call, :call unless method_defined?(:__ar_original_call)
            def call(env)
              cfg = ActiveRabbit::Client.configuration
              ar_puts "\n=== ExceptionMiddleware Enter ==="
              ar_puts "Path: #{env['PATH_INFO']}"
              ar_puts "Method: #{env['REQUEST_METHOD']}"
              ar_puts "Current Exception: #{env['action_dispatch.exception']&.class} - #{env['action_dispatch.exception']&.message}"
              ar_puts "Current Error: #{env['action_dispatch.error']&.class} - #{env['action_dispatch.error']&.message}"
              ar_puts "Rack Exception: #{env['rack.exception']&.class} - #{env['rack.exception']&.message}"
              ar_puts "Exception Backtrace: #{env['action_dispatch.exception']&.backtrace&.first(3)&.join("\n                    ")}"
              ar_puts "Error Backtrace: #{env['action_dispatch.error']&.backtrace&.first(3)&.join("\n                ")}"
              ar_puts "Rack Backtrace: #{env['rack.exception']&.backtrace&.first(3)&.join("\n               ")}"
              ar_puts "============================\n"

              begin
                status, headers, body = __ar_original_call(env)
                ar_puts "\n=== ExceptionMiddleware Exit (Success) ==="
                ar_puts "Status: #{status}"
                ar_puts "Headers: #{headers.inspect}"
                ar_puts "Final Exception: #{env['action_dispatch.exception']&.class} - #{env['action_dispatch.exception']&.message}"
                ar_puts "Final Error: #{env['action_dispatch.error']&.class} - #{env['action_dispatch.error']&.message}"
                ar_puts "Final Rack Exception: #{env['rack.exception']&.class} - #{env['rack.exception']&.message}"
                ar_puts "Final Exception Backtrace: #{env['action_dispatch.exception']&.backtrace&.first(3)&.join("\n                          ")}"
                ar_puts "Final Error Backtrace: #{env['action_dispatch.error']&.backtrace&.first(3)&.join("\n                      ")}"
                ar_puts "Final Rack Backtrace: #{env['rack.exception']&.backtrace&.first(3)&.join("\n                     ")}"
                ar_puts "===========================\n"
                [status, headers, body]
              rescue => e
                ar_puts "\n=== ExceptionMiddleware Exit (Error) ==="
                ar_puts "Error: #{e.class} - #{e.message}"
                ar_puts "Error Backtrace: #{e.backtrace&.first(3)&.join("\n              ")}"
                ar_puts "Original Exception: #{env['action_dispatch.exception']&.class} - #{env['action_dispatch.exception']&.message}"
                ar_puts "Original Error: #{env['action_dispatch.error']&.class} - #{env['action_dispatch.error']&.message}"
                ar_puts "Original Rack Exception: #{env['rack.exception']&.class} - #{env['rack.exception']&.message}"
                ar_puts "Original Exception Backtrace: #{env['action_dispatch.exception']&.backtrace&.first(3)&.join("\n                          ")}"
                ar_puts "Original Error Backtrace: #{env['action_dispatch.error']&.backtrace&.first(3)&.join("\n                      ")}"
                ar_puts "Original Rack Backtrace: #{env['rack.exception']&.backtrace&.first(3)&.join("\n                     ")}"
                ar_puts "===========================\n"
                raise
              end
            end
          end

          # Wrap RoutingErrorCatcher for detailed error tracking
          ActiveRabbit::Client::RoutingErrorCatcher.class_eval do
            alias_method :__ar_routing_original_call, :call unless method_defined?(:__ar_routing_original_call)
            def call(env)
              ar_puts "\n=== RoutingErrorCatcher Enter ==="
              ar_puts "Path: #{env['PATH_INFO']}"
              ar_puts "Method: #{env['REQUEST_METHOD']}"
              ar_puts "Status: #{env['action_dispatch.exception']&.class}"
              ar_puts "============================\n"

              begin
                status, headers, body = __ar_routing_original_call(env)
                ar_puts "\n=== RoutingErrorCatcher Exit (Success) ==="
                ar_puts "Status: #{status}"
                ar_puts "===========================\n"
                [status, headers, body]
              rescue => e
                ar_puts "\n=== RoutingErrorCatcher Exit (Error) ==="
                ar_puts "Error: #{e.class} - #{e.message}"
                ar_puts "Backtrace: #{e.backtrace&.first(3)&.join("\n           ")}"
                ar_puts "===========================\n"
                raise
              end
            end
          end
        end

        # In development, add a hook to verify middleware after initialization
        if Rails.env.development?
          app.config.after_initialize do
            ar_log(:info, "\n=== ActiveRabbit Configuration ===")
            ar_log(:info, "Version: #{ActiveRabbit::Client::VERSION}")
            ar_log(:info, "Environment: #{Rails.env}")
            ar_log(:info, "API URL: #{ActiveRabbit::Client.configuration.api_url}")
            ar_log(:info, "================================")

            ar_log(:info, "\n=== Middleware Stack ===")
            (Rails.application.middleware.middlewares rescue []).each do |mw|
              klass = (mw.respond_to?(:klass) ? mw.klass.name : mw.to_s) rescue mw.inspect
              ar_log(:info, "  #{klass}")
            end
            ar_log(:info, "=======================")

            # Skip missing-middleware warnings in development since we may inject via alternate paths
            unless Rails.env.development?
              # Verify our middleware is present
              our_middleware = [
                ActiveRabbit::Client::ExceptionMiddleware,
                ActiveRabbit::Client::RequestContextMiddleware,
                ActiveRabbit::Client::RoutingErrorCatcher
              ]

              stack_list = (Rails.application.middleware.middlewares rescue [])
              missing = our_middleware.reject { |m| stack_list.any? { |x| (x.respond_to?(:klass) ? x.klass == m : false) } }

              if missing.any?
                Rails.logger.warn "\n⚠️  Missing ActiveRabbit middleware:"
                missing.each { |m| Rails.logger.warn "  - #{m}" }
                Rails.logger.warn "This might affect error tracking!"
              end
            end
          end
        end

        ar_log(:info, "[ActiveRabbit] Middleware configured successfully")
      end

      initializer "active_rabbit.error_reporter" do |app|
        # DISABLED: Rails error reporter creates duplicate events because middleware already catches all errors
        # The middleware provides better context and catches errors at the right level
        # app.config.after_initialize do
        #   ActiveRabbit::Client::ErrorReporter.attach!
        # end
      end

      initializer "active_rabbit.sidekiq" do
        next unless defined?(Sidekiq)

        # Report unhandled Sidekiq job errors
        Sidekiq.configure_server do |config|
          config.error_handlers << proc do |exception, context|
            begin
              ActiveRabbit::Client.track_exception(
                exception,
                context: { source: 'sidekiq', job: context }
              )
            rescue => e
              Rails.logger.error "[ActiveRabbit] Sidekiq error handler failed: #{e.class} - #{e.message}" if defined?(Rails)
            end
          end
        end
      end

      initializer "active_rabbit.active_job" do |app|
        next unless defined?(ActiveJob)

        # Load extension
        begin
          require_relative "active_job_extensions"
        rescue LoadError
        end

        app.config.after_initialize do
          begin
            ActiveJob::Base.include(ActiveRabbit::Client::ActiveJobExtensions)
          rescue => e
            Rails.logger.error "[ActiveRabbit] Failed to include ActiveJobExtensions: #{e.message}" if defined?(Rails)
          end
        end
      end

      initializer "active_rabbit.action_mailer" do |app|
        next unless defined?(ActionMailer)

        begin
          require_relative "action_mailer_patch"
        rescue LoadError
        end
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

      # Boot diagnostics to confirm wiring
      initializer "active_rabbit.boot_diagnostics" do |app|
        app.config.after_initialize do
          begin
            reporting_file, reporting_line = ActiveRabbit::Reporting.method(:report_exception).source_location
            http_file, http_line = ActiveRabbit::Client::HttpClient.instance_method(:post_exception).source_location
            ar_log(:info, "[ActiveRabbit] Reporting loaded from #{reporting_file}:#{reporting_line}") if defined?(Rails)
            ar_log(:info, "[ActiveRabbit] HttpClient#post_exception from #{http_file}:#{http_line}") if defined?(Rails)
          rescue => e
            Rails.logger.debug "[ActiveRabbit] boot diagnostics failed: #{e.message}" if defined?(Rails)
          end
        end
      end

      private

      def ar_puts(msg)
        cfg = ActiveRabbit::Client.configuration
        return if cfg && cfg.disable_console_logs
        puts msg
      end

      def ar_log(level, msg)
        cfg = ActiveRabbit::Client.configuration
        return if cfg && cfg.disable_console_logs
        Rails.logger.public_send(level, msg) if Rails.logger
      end

      def apply_rails_configuration(rails_config)
        return unless rails_config

        options = rails_config.respond_to?(:to_h) ? rails_config.to_h : rails_config
        return if options.nil? || options.empty?

        ActiveRabbit::Client.configure do |config|
          options.each do |key, value|
            next if value.nil?

            writer = "#{key}="
            config.public_send(writer, value) if config.respond_to?(writer)
          end
        end
      end

      def setup_exception_tracking(app)
        # Handle uncaught exceptions in development
        if Rails.env.development? || Rails.env.test?
          app.config.consider_all_requests_local = false if Rails.env.test?
        end
      end

      def subscribe_to_controller_events
        ar_log(:info, "[ActiveRabbit] Subscribing to controller events (configured=#{ActiveRabbit::Client.configured?})")

        ActiveSupport::Notifications.subscribe "process_action.action_controller" do |name, started, finished, unique_id, payload|
          begin
            unless ActiveRabbit::Client.configured?
              Rails.logger.debug "[ActiveRabbit] Skipping performance tracking - not configured"
              next
            end

            duration_ms = ((finished - started) * 1000).round(2)

            ar_log(:info, "[ActiveRabbit] 📊 Controller action: #{payload[:controller]}##{payload[:action]} - #{duration_ms}ms")
            ar_log(:info, "[ActiveRabbit] 📊 DB runtime: #{payload[:db_runtime]}, View runtime: #{payload[:view_runtime]}")

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
            handled: true,
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
        # debug start - using Rails.logger to ensure it appears in development.log
        ar_log(:info, "[AR] ExceptionMiddleware ENTER path=#{env['PATH_INFO']}") if defined?(Rails)
        warn "[AR] ExceptionMiddleware ENTER path=#{env['PATH_INFO']}"
        warn "[AR] Current exceptions in env:"
        warn "  - action_dispatch.exception: #{env['action_dispatch.exception']&.class}"
        warn "  - rack.exception: #{env['rack.exception']&.class}"
        warn "  - action_dispatch.error: #{env['action_dispatch.error']&.class}"

        begin
          # Try to call the app, catch any exceptions
          status, headers, body = @app.call(env)
          warn "[AR] App call completed with status: #{status}"

          # Check for exceptions in env after app call
          if (ex = env["action_dispatch.exception"] || env["rack.exception"] || env["action_dispatch.error"])
            ar_log(:info, "[AR] env exception present: #{ex.class}: #{ex.message}") if defined?(Rails)
            warn "[AR] env exception present: #{ex.class}: #{ex.message}"
            warn "[AR] Exception backtrace: #{ex.backtrace&.first(3)&.join("\n           ")}"
            safe_report(ex, env, 'Rails rescued exception')
          else
            ar_log(:info, "[AR] env exception NOT present") if defined?(Rails)
            warn "[AR] env exception NOT present"
            warn "[AR] Final env check:"
            warn "  - action_dispatch.exception: #{env['action_dispatch.exception']&.class}"
            warn "  - rack.exception: #{env['rack.exception']&.class}"
            warn "  - action_dispatch.error: #{env['action_dispatch.error']&.class}"
          end

          # Return the response
          [status, headers, body]
        rescue => e
          # Primary path: catch raw exceptions before Rails rescuers
          ar_log(:info, "[AR] RESCUE caught: #{e.class}: #{e.message}") if defined?(Rails)
          warn "[AR] RESCUE caught: #{e.class}: #{e.message}"
          warn "[AR] Rescue backtrace: #{e.backtrace&.first(3)&.join("\n           ")}"

          # Report the exception
          safe_report(e, env, 'Raw exception caught')

          # Let Rails handle the exception
          env["action_dispatch.exception"] = e
          env["rack.exception"] = e
          raise
        end
      end

      private

      def safe_report(exception, env, source)
        begin
          request = ActionDispatch::Request.new(env)
          warn "[AR] safe_report called for #{source}"
          warn "[AR] Exception: #{exception.class.name} - #{exception.message}"
          warn "[AR] Backtrace: #{exception.backtrace&.first(3)&.join("\n           ")}"

          context = {
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
              source: source,
              timestamp: Time.now.iso8601(3)
            }
          }

          warn "[AR] Tracking with context: #{context.inspect}"

          result = ActiveRabbit::Client.track_exception(exception, context: context)
          warn "[AR] Track result: #{result.inspect}"

          ar_log(:info, "[ActiveRabbit] Tracked #{source}: #{exception.class.name} - #{exception.message}") if defined?(Rails)
        rescue => tracking_error
          # Log tracking errors but don't let them interfere with exception handling
          warn "[AR] Error in safe_report: #{tracking_error.class} - #{tracking_error.message}"
          warn "[AR] Error backtrace: #{tracking_error.backtrace&.first(3)&.join("\n           ")}"
          Rails.logger.error "[ActiveRabbit] Error tracking exception: #{tracking_error.message}" if defined?(Rails)
        end
      end

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

    # Middleware for catching routing errors
    class RoutingErrorCatcher
      def initialize(app) = @app = app

      def call(env)
        status, headers, body = @app.call(env)

        if status == 404
          Rails.logger.debug "[ActiveRabbit] RoutingErrorCatcher: 404 detected for #{env['PATH_INFO']}"
          exception = env["action_dispatch.exception"] || env["rack.exception"] || env["action_dispatch.error"]

          if exception && exception.is_a?(ActionController::RoutingError)
            Rails.logger.debug "[ActiveRabbit] Routing error caught: #{exception.message}"
            track_routing_error(exception, env)
          else
            # If no exception found in env, create one manually for 404s on non-asset paths
            if env['PATH_INFO'] && !env['PATH_INFO'].match?(/\.(css|js|png|jpg|gif|ico|svg)$/)
              synthetic_error = create_synthetic_error(env)
              track_routing_error(synthetic_error, env)
            end
          end
        end

        [status, headers, body]
      rescue => e
        # Catch any routing errors that weren't handled by Rails
        if e.is_a?(ActionController::RoutingError)
          Rails.logger.debug "[ActiveRabbit] Unhandled routing error caught: #{e.message}"
          track_routing_error(e, env, handled: false)
        end
        raise
      end

      private

      def create_synthetic_error(env)
        error = ActionController::RoutingError.new("No route matches [#{env['REQUEST_METHOD']}] \"#{env['PATH_INFO']}\"")
        error.set_backtrace([
          "#{Rails.root}/config/routes.rb:1:in `route_not_found'",
          "#{__FILE__}:#{__LINE__}:in `call'",
          "actionpack/lib/action_dispatch/middleware/debug_exceptions.rb:31:in `call'"
        ])
        error
      end

      def track_routing_error(error, env, handled: true)
        return unless defined?(ActiveRabbit::Client)

        context = {
          controller_action: 'Routing#not_found',
          error_type: 'Route Not Found',
          error_message: error.message,
          error_location: error.backtrace&.first,
          error_severity: :warning,
          error_status: 404,
          error_source: 'Router',
          error_component: 'ActionDispatch',
          error_action: 'route_lookup',
          request_details: "#{env['REQUEST_METHOD']} #{env['PATH_INFO']} (No Route)",
          response_time: "N/A (Routing Error)",
          routing_info: "No matching route for path: #{env['PATH_INFO']}",
          environment: Rails.env,
          occurred_at: Time.current.iso8601(3),
          request_path: env['PATH_INFO'],
          request_method: env['REQUEST_METHOD'],
          handled: handled,
          error: {
            class: error.class.name,
            message: error.message,
            backtrace_preview: error.backtrace&.first(3),
            handled: handled,
            severity: :warning,
            framework: 'Rails',
            component: 'Router',
            error_group: 'Routing Error',
            error_type: 'route_not_found'
          },
          request: {
            method: env['REQUEST_METHOD'],
            path: env['PATH_INFO'],
            query_string: env['QUERY_STRING'],
            user_agent: env['HTTP_USER_AGENT'],
            ip_address: env['REMOTE_ADDR']
          },
          routing: {
            attempted_path: env['PATH_INFO'],
            available_routes: 'See Rails routes',
            error_type: 'route_not_found'
          },
          source: 'routing_error_catcher',
          tags: {
            error_type: 'routing_error',
            handled: handled,
            severity: 'warning'
          }
        }

        # Force reporting so 404 ignore filters don't drop this
        ActiveRabbit::Client.track_exception(error, context: context, handled: handled, force: true)
      end
    end
  end
end
