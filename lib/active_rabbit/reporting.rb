# frozen_string_literal: true

require "time"

module ActiveRabbit
  module Reporting
    module_function

    def report_exception(exception, env: nil, context: {}, handled: false, source: "rails", force: false)
      return unless defined?(ActiveRabbit::Client) && ActiveRabbit::Client.configured?

      enriched_context = (context || {}).dup
      req_info = env ? rack_request_info(env) : { request: {}, routing: {} }
      enriched_context[:request] ||= req_info[:request]
      enriched_context[:routing] ||= req_info[:routing]
      enriched_context[:source] ||= source
      enriched_context[:handled] = handled if !enriched_context.key?(:handled)

      # Extract controller_action from routing info to prevent duplicate issues
      routing = req_info[:routing]
      if routing && routing[:controller] && routing[:action] && !enriched_context[:controller_action]
        controller_name = routing[:controller].to_s
        action_name = routing[:action].to_s
        enriched_context[:controller_action] = "#{controller_name}##{action_name}"
      end

      # Enrich for routing errors so UI shows controller action and 404 specifics
      if defined?(ActionController::RoutingError) && exception.is_a?(ActionController::RoutingError)
        enriched_context[:controller_action] ||= 'Routing#not_found'
        enriched_context[:error_type] ||= 'route_not_found'
        enriched_context[:error_status] ||= 404
        enriched_context[:error_component] ||= 'ActionDispatch'
        enriched_context[:error_source] ||= 'Router'
        enriched_context[:tags] = (enriched_context[:tags] || {}).merge(error_type: 'routing_error', severity: 'warning')
      end

      ActiveRabbit::Client.track_exception(exception,
        context: enriched_context,
        handled: handled,
        force: force)
    rescue => e
      if defined?(Rails)
        ActiveRabbit::Client.log(:error, "[ActiveRabbit] report_exception failed: #{e.class}: #{e.message}")
      end
      nil
    end

    def rack_request_info(env)
      req = ActionDispatch::Request.new(env)
      {
        request: {
          method: req.request_method,
          path: req.fullpath,
          ip_address: req.ip,
          user_agent: req.user_agent,
          request_id: req.request_id
        },
        routing: {
          path: req.path,
          params: (req.respond_to?(:filtered_parameters) ? req.filtered_parameters : (env["action_dispatch.request.parameters"] || {})),
          controller: env["action_controller.instance"]&.class&.name,
          action: (env["action_dispatch.request.parameters"]&.dig("action"))
        }
      }
    rescue
      { request: {}, routing: {} }
    end
  end
end


