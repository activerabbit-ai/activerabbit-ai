# frozen_string_literal: true

module ActiveRabbit
  module Client
    module ErrorReporter
      class Subscriber
        def report(exception, handled:, severity:, context:, source: nil)
          Rails.logger.info "[ActiveRabbit] Error reporter caught: #{exception.class}: #{exception.message}" if defined?(Rails.logger)

          ActiveRabbit::Client.track_exception(exception, context: {
            handled: handled,
            severity: severity,
            framework_context: context || {},
            source: 'Rails error reporter'
          })
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
