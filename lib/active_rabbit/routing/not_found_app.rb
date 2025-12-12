# frozen_string_literal: true

module ActiveRabbit
  module Routing
    class NotFoundApp
      def call(env)
        error = ActionController::RoutingError.new("No route matches #{env['REQUEST_METHOD']} #{env['PATH_INFO']}")
        begin
          ActiveRabbit::Reporting.report_exception(error, env: env, handled: true, source: "router", force: true)
        rescue => e
          ActiveRabbit::Client.log(:error, "[ActiveRabbit] NotFoundApp failed to report: #{e.class}: #{e.message}")
        end
        [404, { "Content-Type" => "text/plain" }, ["Not Found"]]
      end
    end
  end
end


