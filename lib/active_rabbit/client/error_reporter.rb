# frozen_string_literal: true
require 'set'
require_relative '../reporting'

module ActiveRabbit
  module Client
    module ErrorReporter
      class Subscriber
        def report(exception, handled:, severity:, context:, source: nil)
          begin
            Rails.logger.info "[ActiveRabbit] Error reporter caught: #{exception.class}: #{exception.message}" if defined?(Rails.logger)

            # Time-based deduplication: track errors with timestamps
            $reported_errors ||= {}

            # Generate a unique key for this error
            error_key = "#{exception.class.name}:#{exception.message}:#{exception.backtrace&.first}"

            # Get dedupe window from config (default 5 minutes, 0 = disabled)
            dedupe_window = defined?(ActiveRabbit::Client.configuration.dedupe_window) ?
                            ActiveRabbit::Client.configuration.dedupe_window : 300

            current_time = Time.now.to_i
            last_seen = $reported_errors[error_key]

            # Report if: never seen before, OR dedupe disabled (0), OR outside dedupe window
            should_report = last_seen.nil? || dedupe_window == 0 || (current_time - last_seen) > dedupe_window

            if should_report
              $reported_errors[error_key] = current_time

              # Clean old entries to prevent memory leak (keep last hour)
              $reported_errors.delete_if { |_, timestamp| current_time - timestamp > 3600 }

              enriched = build_enriched_context(exception, handled: handled, severity: severity, context: context)
              ActiveRabbit::Client.track_exception(exception, handled: handled, context: enriched)
            else
              Rails.logger.debug "[ActiveRabbit] Error deduplicated (last seen #{current_time - last_seen}s ago)" if defined?(Rails.logger)
            end
          rescue => e
            Rails.logger.error "[ActiveRabbit] Error in ErrorReporter::Subscriber#report: #{e.class} - #{e.message}" if defined?(Rails.logger)
          end
        end

        private

        def build_enriched_context(exception, handled:, severity:, context: {})
          ctx = { handled: handled, severity: severity, source: 'rails_error_reporter' }
          ctx[:framework_context] = context || {}

          env = context && (context[:env] || context['env'])
          if env
            req_info = ActiveRabbit::Reporting.rack_request_info(env)
            ctx[:request] = req_info[:request]
            ctx[:routing] = req_info[:routing]
            # Top-level convenience for UI
            ctx[:request_path] = ctx[:request][:path]
            ctx[:request_method] = ctx[:request][:method]
          end

          if defined?(ActionController::RoutingError) && exception.is_a?(ActionController::RoutingError)
            ctx[:controller_action] = 'Routing#not_found'
            ctx[:error_type] = 'route_not_found'
            ctx[:error_status] = 404
            ctx[:error_component] = 'ActionDispatch'
            ctx[:error_source] = 'Router'
            ctx[:tags] = (ctx[:tags] || {}).merge(error_type: 'routing_error', severity: 'warning')
          end

          ctx
        end
      end

      def self.attach!
        # Rails 7.0+: Rails.error; earlier versions no-op
        if defined?(Rails) && Rails.respond_to?(:error)
          Rails.logger.info "[ActiveRabbit] Attaching to Rails error reporter" if defined?(Rails.logger)

          subscriber = Subscriber.new
          Rails.error.subscribe(subscriber)

          Rails.logger.info "[ActiveRabbit] Rails error reporter attached successfully" if defined?(Rails.logger)
        else
          Rails.logger.info "[ActiveRabbit] Rails error reporter not available (Rails < 7.0)" if defined?(Rails.logger)
        end
      end
    end
  end
end
