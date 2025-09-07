# frozen_string_literal: true
require 'set'

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
              ActiveRabbit::Client.track_exception(exception, context: {
                handled: handled,
                severity: severity,
                framework_context: context || {},
                source: 'Rails error reporter'
              })
            end
          rescue => e
            Rails.logger.error "[ActiveRabbit] Error in ErrorReporter::Subscriber#report: #{e.class} - #{e.message}" if defined?(Rails.logger)
          end
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
