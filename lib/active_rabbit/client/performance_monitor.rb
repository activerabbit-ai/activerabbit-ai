# frozen_string_literal: true

module ActiveRabbit
  module Client
    class PerformanceMonitor
      attr_reader :configuration, :http_client

      def initialize(configuration, http_client)
        @configuration = configuration
        @http_client = http_client
        @active_transactions = Concurrent::Hash.new
      end

      def track_performance(name:, duration_ms:, metadata: {})
        return unless configuration.enable_performance_monitoring

        performance_data = build_performance_data(
          name: name,
          duration_ms: duration_ms,
          metadata: metadata
        )

        http_client.post_performance(performance_data)
      end

      def start_transaction(name, metadata: {})
        return unless configuration.enable_performance_monitoring

        transaction_id = SecureRandom.uuid
        @active_transactions[transaction_id] = {
          name: name,
          start_time: Time.now,
          metadata: metadata
        }

        transaction_id
      end

      def finish_transaction(transaction_id, additional_metadata: {})
        return unless configuration.enable_performance_monitoring
        return unless @active_transactions.key?(transaction_id)

        transaction = @active_transactions.delete(transaction_id)
        duration_ms = ((Time.now - transaction[:start_time]) * 1000).round(2)

        track_performance(
          name: transaction[:name],
          duration_ms: duration_ms,
          metadata: transaction[:metadata].merge(additional_metadata)
        )
      end

      def measure(name, metadata: {})
        return yield unless configuration.enable_performance_monitoring

        start_time = Time.now
        result = yield
        end_time = Time.now

        duration_ms = ((end_time - start_time) * 1000).round(2)

        track_performance(
          name: name,
          duration_ms: duration_ms,
          metadata: metadata
        )

        result
      end

      def flush
        # Performance monitor sends immediately, no batching needed
      end

      private

      def build_performance_data(name:, duration_ms:, metadata:)
        data = {
          name: name.to_s,
          duration_ms: duration_ms.to_f,
          metadata: scrub_pii(metadata || {}),
          timestamp: Time.now.iso8601(3),
          environment: configuration.environment,
          release: configuration.release,
          server_name: configuration.server_name
        }

        data[:project_id] = configuration.project_id if configuration.project_id

        # Add performance context
        data[:performance_context] = build_performance_context

        # Add request context if available
        if defined?(Thread) && Thread.current[:active_rabbit_request_context]
          data[:request_context] = Thread.current[:active_rabbit_request_context]
        end

        data
      end

      def build_performance_context
        context = {}

        # Memory usage
        begin
          if defined?(GC)
            gc_stats = GC.stat
            context[:memory] = {
              heap_allocated_pages: gc_stats[:heap_allocated_pages],
              heap_sorted_length: gc_stats[:heap_sorted_length],
              heap_allocatable_pages: gc_stats[:heap_allocatable_pages],
              heap_available_slots: gc_stats[:heap_available_slots],
              heap_live_slots: gc_stats[:heap_live_slots],
              heap_free_slots: gc_stats[:heap_free_slots],
              total_allocated_pages: gc_stats[:total_allocated_pages]
            }
          end
        rescue
          # Ignore if GC stats are not available
        end

        # Process information
        begin
          context[:process] = {
            pid: Process.pid
          }
        rescue
          # Ignore if process info is not available
        end

        # Thread information
        begin
          context[:threading] = {
            active_threads: Thread.list.size
          }
        rescue
          # Ignore if thread info is not available
        end

        context
      end

      def scrub_pii(data)
        return data unless configuration.enable_pii_scrubbing

        PiiScrubber.new(configuration).scrub(data)
      end
    end
  end
end
