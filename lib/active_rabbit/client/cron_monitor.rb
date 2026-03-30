# frozen_string_literal: true

module ActiveRabbit
  module Client
    # Sentry-style cron check-ins for Active Job: in_progress at start, ok on success, error on failure.
    #
    #   class BackupJob < ApplicationJob
    #     include ActiveRabbit::Client::CronMonitor
    #     active_rabbit_cron slug: "nightly_backup"
    #
    #     def perform
    #       # ...
    #     end
    #   end
    module CronMonitor
      def self.included(base)
        base.extend(ClassMethods)
        base.class_eval do
          around_perform :_active_rabbit_cron_monitor_around
        end
      end

      module ClassMethods
        # @param value [String, Symbol, Hash] string/symbol slug, or { slug: "..." }
        def active_rabbit_cron(value = nil)
          case value
          when String, Symbol
            @active_rabbit_cron_slug = value.to_s.strip
          when Hash
            s = value[:slug].to_s.strip
            @active_rabbit_cron_slug = s.empty? ? nil : s
          when nil
            @active_rabbit_cron_slug = nil
          end
        end

        def active_rabbit_cron_monitor_slug
          slug = instance_variable_defined?(:@active_rabbit_cron_slug) ? @active_rabbit_cron_slug : nil
          return slug if slug.is_a?(String) && !slug.strip.empty?

          name.to_s.underscore.tr("/", "_")
        end
      end

      private

      def _active_rabbit_cron_monitor_around(&block)
        slug = self.class.active_rabbit_cron_monitor_slug
        if slug.to_s.strip.empty? || !ActiveRabbit::Client.configured?
          block.call
          return
        end

        ActiveRabbit::Client.capture_cron_check_in(slug, :in_progress)
        begin
          block.call
        rescue StandardError => e
          ActiveRabbit::Client.capture_cron_check_in(slug, :error)
          raise e
        end
        ActiveRabbit::Client.capture_cron_check_in(slug, :ok)
      end
    end
  end
end
