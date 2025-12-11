# frozen_string_literal: true

module ActiveRabbit
  module Middleware
    class ErrorCaptureMiddleware
      def initialize(app)
        @app = app
      end

      def call(env)
        @app.call(env)
      rescue => e
        begin
          ActiveRabbit::Reporting.report_exception(e, env: env, handled: false, source: "middleware", force: true)
        rescue => inner
          ActiveRabbit::Client.log(:error, "[ActiveRabbit] ErrorCaptureMiddleware failed: #{inner.class}: #{inner.message}")
        end
        raise
      end
    end
  end
end


