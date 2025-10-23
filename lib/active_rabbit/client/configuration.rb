# frozen_string_literal: true

require "socket"
require "logger"

module ActiveRabbit
  module Client
    class Configuration
      attr_accessor :api_key, :api_url, :project_id, :environment
      attr_accessor :timeout, :open_timeout, :retry_count, :retry_delay
      attr_accessor :batch_size, :flush_interval, :queue_size
      attr_accessor :enable_performance_monitoring, :enable_n_plus_one_detection
      attr_accessor :enable_pii_scrubbing, :pii_fields
      attr_accessor :ignored_exceptions, :ignored_user_agents, :ignore_404
      attr_accessor :release, :server_name, :logger
      attr_accessor :before_send_event, :before_send_exception
      attr_accessor :dedupe_window  # Time window in seconds for error deduplication (0 = disabled)

      def initialize
        @api_url = ENV.fetch("active_rabbit_API_URL", "https://api.activerabbit.ai")
        @api_key = ENV["active_rabbit_API_KEY"]
        @project_id = ENV["active_rabbit_PROJECT_ID"]
        @environment = ENV.fetch("active_rabbit_ENVIRONMENT", detect_environment)

        # HTTP settings
        @timeout = 30
        @open_timeout = 10
        @retry_count = 3
        @retry_delay = 1

        # Batching settings
        @batch_size = 100
        @flush_interval = 30 # seconds
        @queue_size = 1000

        # Feature flags
        @enable_performance_monitoring = true
        @enable_n_plus_one_detection = true
        @enable_pii_scrubbing = true

        # PII scrubbing
        @pii_fields = %w[
          password password_confirmation token secret key
          credit_card ssn social_security_number phone email
          first_name last_name name address city state zip
        ]

        # Filtering
        # default ignores (404 controlled by ignore_404)
        @ignore_404 = true
        @ignored_exceptions = %w[
          ActiveRecord::RecordNotFound
          ActionController::InvalidAuthenticityToken
          CGI::Session::CookieStore::TamperedWithCookie
        ]

        @ignored_user_agents = [
          /Googlebot/i,
          /bingbot/i,
          /facebookexternalhit/i,
          /Twitterbot/i
        ]

        # Deduplication (0 = disabled, time in seconds for same error to be considered duplicate)
        @dedupe_window = 300  # 5 minutes by default

        # Metadata
        @release = detect_release
        @server_name = detect_server_name
        @logger = detect_logger

        # Callbacks
        @before_send_event = nil
        @before_send_exception = nil
      end

      def valid?
        return false unless api_key
        return false if api_key.empty?
        return false unless api_url
        return false if api_url.empty?
        true
      end

      def api_endpoint(path)
        "#{api_url.chomp('/')}/#{path.to_s.sub(/^\//, '')}"
      end

      def should_ignore_exception?(exception)
        return false unless exception
        # Special-case 404 via flag
        if @ignore_404
          begin
            return true if exception.is_a?(ActionController::RoutingError)
          rescue NameError
            # Ignore if AC not loaded
          end
        end

        ignored_exceptions.any? do |ignored|
          case ignored
          when String
            exception.class.name == ignored
          when Class
            exception.is_a?(ignored)
          when Regexp
            exception.class.name =~ ignored
          else
            false
          end
        end
      end

      def should_ignore_user_agent?(user_agent)
        return false unless user_agent

        ignored_user_agents.any? do |pattern|
          case pattern
          when String
            user_agent.include?(pattern)
          when Regexp
            user_agent =~ pattern
          else
            false
          end
        end
      end

      private

      def detect_environment
        return Rails.env if defined?(Rails) && Rails.respond_to?(:env)
        return Sinatra::Base.environment.to_s if defined?(Sinatra)

        ENV["RACK_ENV"] || ENV["RAILS_ENV"] || "development"
      end

      def detect_release
        # Try to detect from common CI/deployment environment variables
        ENV["HEROKU_SLUG_COMMIT"] ||
          ENV["GITHUB_SHA"] ||
          ENV["GITLAB_COMMIT_SHA"] ||
          ENV["CIRCLE_SHA1"] ||
          ENV["TRAVIS_COMMIT"] ||
          ENV["BUILD_VCS_NUMBER"] ||
          detect_git_sha
      end

      def detect_git_sha
        return unless File.directory?(".git")

        `git rev-parse HEAD 2>/dev/null`.chomp
      rescue
        nil
      end

      def detect_server_name
        ENV["DYNO"] || # Heroku
          ENV["HOSTNAME"] || # Docker
          ENV["SERVER_NAME"] ||
          Socket.gethostname
      rescue
        "unknown"
      end

      def detect_logger
        return Rails.logger if defined?(Rails) && Rails.respond_to?(:logger)

        Logger.new($stdout).tap do |logger|
          logger.level = Logger::INFO
        end
      end
    end
  end
end
