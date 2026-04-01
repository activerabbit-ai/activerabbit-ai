# frozen_string_literal: true

require "net/http"
require "json"
require "logger"

module ActiveRabbit
  module Client
    # Logger subclass that buffers log entries and forwards them in batches to
    # the ActiveRabbit POST /api/v1/logs endpoint.
    #
    # Plugged into ActiveSupport::BroadcastLogger automatically by the Railtie
    # when `config.enable_logs = true`, so every Rails.logger call is forwarded
    # without touching application code.
    class LogForwarder < ::Logger
      SEVERITY_MAP = { 0 => "debug", 1 => "info", 2 => "warn",
                       3 => "error", 4 => "fatal", 5 => "info" }.freeze

      MAX_MESSAGE_LEN = 10_000

      def initialize(configuration)
        @configuration = configuration
        @buffer = []
        @mutex  = Mutex.new
        @uri    = URI("#{configuration.api_url.chomp('/')}/api/v1/logs")
        @stopped = false

        super(File::NULL, level: ::Logger::DEBUG)
        self.formatter = proc { |*, msg| msg }

        start_flusher
      end

      # -- Logger interface --------------------------------------------------

      def add(severity, message = nil, progname = nil, &block)
        return true if Thread.current[:_ar_log_sending]

        severity ||= UNKNOWN
        return true if severity < level

        message = block&.call if message.nil? && block
        message ||= progname
        return true if message.nil?

        msg = message.to_s.strip
        return true if msg.empty?
        msg = msg[0, MAX_MESSAGE_LEN] if msg.length > MAX_MESSAGE_LEN

        entry = build_entry(severity, msg)
        @mutex.synchronize { @buffer << entry }
        async_flush if buffer_size >= batch_size
        true
      end

      def flush
        entries = swap_buffer
        send_batch(entries) if entries&.any?
      end

      def stop
        @stopped = true
        flush
      end

      private

      def build_entry(severity, message)
        ctx = Thread.current[:active_rabbit_request_context]

        {
          level:       SEVERITY_MAP[severity] || "info",
          message:     message,
          source:      @configuration.logs_source || "rails",
          environment: @configuration.environment || (defined?(Rails) ? Rails.env.to_s : "production"),
          occurred_at: Time.now.utc.strftime("%Y-%m-%dT%H:%M:%S.%6NZ"),
          request_id:  ctx&.dig(:request_id),
          context:     { pid: Process.pid }
        }.compact
      end

      def batch_size
        @configuration.logs_batch_size || 100
      end

      def flush_interval
        @configuration.logs_flush_interval || 5
      end

      def buffer_size
        @mutex.synchronize { @buffer.size }
      end

      def swap_buffer
        @mutex.synchronize do
          return nil if @buffer.empty?
          out = @buffer.dup
          @buffer.clear
          out
        end
      end

      def async_flush
        Thread.new { flush }
      end

      def start_flusher
        Thread.new do
          loop do
            sleep flush_interval
            break if @stopped
            flush
          rescue StandardError
            nil
          end
        end
      end

      def send_batch(entries)
        return if entries.nil? || entries.empty?

        Thread.current[:_ar_log_sending] = true

        entries.each_slice(1000) do |chunk|
          http = Net::HTTP.new(@uri.host, @uri.port)
          http.use_ssl = (@uri.scheme == "https")
          http.open_timeout = 5
          http.read_timeout = 10

          req = Net::HTTP::Post.new(@uri)
          req["Content-Type"]    = "application/json"
          req["X-Project-Token"] = @configuration.api_key
          req.body = { entries: chunk }.to_json

          http.request(req)
        end
      rescue StandardError
        nil
      ensure
        Thread.current[:_ar_log_sending] = false
      end
    end
  end
end
