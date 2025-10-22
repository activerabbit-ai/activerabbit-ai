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

            # Initialize de-dup set
            $reported_errors ||= Set.new

            # Generate a unique key for this error
            error_key = "#{exception.class.name}:#{exception.message}:#{exception.backtrace&.first}"

            # Only report if we haven't seen this error before
            unless $reported_errors.include?(error_key)
              $reported_errors.add(error_key)

              enriched = build_enriched_context(exception, handled: handled, severity: severity, context: context)
              ActiveRabbit::Client.track_exception(exception, handled: handled, context: enriched)
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
