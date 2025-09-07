# frozen_string_literal: true

require "concurrent"
require "time"

module ActiveRabbit
  module Client
    class EventProcessor
      attr_reader :configuration, :http_client

      def initialize(configuration, http_client)
        @configuration = configuration
        @http_client = http_client
        @event_queue = Concurrent::Array.new
        @processor_thread = nil
        @shutdown = false
      end

      def track_event(name:, properties: {}, user_id: nil, timestamp: nil)
        return if @shutdown

        event_data = build_event_data(
          name: name,
          properties: properties,
          user_id: user_id,
          timestamp: timestamp
        )

        # Apply before_send callback if configured
        if configuration.before_send_event
          event_data = configuration.before_send_event.call(event_data)
          return unless event_data # Callback can filter out events by returning nil
        end

        @event_queue << event_data
        ensure_processor_running
      end

      def flush
        return if @event_queue.empty?

        events = @event_queue.shift(@event_queue.length)
        return if events.empty?

        events.each_slice(configuration.batch_size) do |batch|
          http_client.post_batch(batch)
        end
      end

      def shutdown
        @shutdown = true
        @processor_thread&.kill
        flush
      end

      private

      def build_event_data(name:, properties:, user_id:, timestamp:)
        data = {
          name: name.to_s,
          properties: scrub_pii(properties || {}),
          timestamp: (timestamp || Time.now).iso8601(3),
          environment: configuration.environment,
          release: configuration.release,
          server_name: configuration.server_name
        }

        data[:user_id] = user_id if user_id
        data[:project_id] = configuration.project_id if configuration.project_id

        # Add context information
        data[:context] = build_context

        data
      end

      def build_context
        context = {}

        # Runtime information
        context[:runtime] = {
          name: "ruby",
          version: RUBY_VERSION,
          platform: RUBY_PLATFORM
        }

        # Framework information
        if defined?(Rails)
          context[:framework] = {
            name: "rails",
            version: Rails.version
          }
        elsif defined?(Sinatra)
          context[:framework] = {
            name: "sinatra",
            version: Sinatra::VERSION
          }
        end

        # Request information (if available)
        if defined?(Thread) && Thread.current[:active_rabbit_request_context]
          context[:request] = Thread.current[:active_rabbit_request_context]
        end

        # Background job information (if available)
        if defined?(Thread) && Thread.current[:active_rabbit_job_context]
          context[:job] = Thread.current[:active_rabbit_job_context]
        end

        context
      end

      def scrub_pii(data)
        return data unless configuration.enable_pii_scrubbing

        PiiScrubber.new(configuration).scrub(data)
      end

      def ensure_processor_running
        return if @processor_thread&.alive?

        @processor_thread = Thread.new do
          loop do
            break if @shutdown

            begin
              sleep(configuration.flush_interval)
              flush unless @event_queue.empty?
            rescue => e
              configuration.logger&.error("[ActiveRabbit] Event processor error: #{e.message}")
            end
          end
        end
      end
    end
  end
end
