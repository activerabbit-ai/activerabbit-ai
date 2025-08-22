# frozen_string_literal: true

module ActiveRabbit
  module Client
    class SidekiqMiddleware
      def call(worker, job, queue)
        start_time = Time.now
        job_context = build_job_context(worker, job, queue)

        # Set job context for the duration of the job
        Thread.current[:active_rabbit_job_context] = job_context

        begin
          result = yield

          # Track successful job completion
          duration_ms = ((Time.now - start_time) * 1000).round(2)
          track_job_performance(worker, job, queue, duration_ms, "completed")

          result
        rescue Exception => exception
          # Track job failure
          duration_ms = ((Time.now - start_time) * 1000).round(2)
          track_job_performance(worker, job, queue, duration_ms, "failed")
          track_job_exception(exception, worker, job, queue)

          # Re-raise the exception so Sidekiq can handle it
          raise exception
        ensure
          # Clean up job context
          Thread.current[:active_rabbit_job_context] = nil
        end
      end

      private

      def build_job_context(worker, job, queue)
        {
          worker_class: worker.class.name,
          job_id: job["jid"],
          queue: queue,
          args: scrub_job_args(job["args"]),
          retry_count: job["retry_count"] || 0,
          enqueued_at: job["enqueued_at"] ? Time.at(job["enqueued_at"]) : nil,
          created_at: job["created_at"] ? Time.at(job["created_at"]) : nil
        }
      end

      def track_job_performance(worker, job, queue, duration_ms, status)
        return unless ActiveRabbit::Client.configured?

        ActiveRabbit::Client.track_performance(
          "sidekiq.job",
          duration_ms,
          metadata: {
            worker_class: worker.class.name,
            queue: queue,
            status: status,
            job_id: job["jid"],
            retry_count: job["retry_count"] || 0,
            args_count: job["args"]&.size || 0
          }
        )

        # Track slow jobs
        if duration_ms > 30_000 # Slower than 30 seconds
          ActiveRabbit::Client.track_event(
            "slow_sidekiq_job",
            {
              worker_class: worker.class.name,
              queue: queue,
              duration_ms: duration_ms,
              job_id: job["jid"]
            }
          )
        end

        # Track job completion event
        ActiveRabbit::Client.track_event(
          "sidekiq_job_#{status}",
          {
            worker_class: worker.class.name,
            queue: queue,
            duration_ms: duration_ms,
            retry_count: job["retry_count"] || 0
          }
        )
      end

      def track_job_exception(exception, worker, job, queue)
        return unless ActiveRabbit::Client.configured?

        ActiveRabbit::Client.track_exception(
          exception,
          context: {
            job: {
              worker_class: worker.class.name,
              queue: queue,
              job_id: job["jid"],
              args: scrub_job_args(job["args"]),
              retry_count: job["retry_count"] || 0,
              enqueued_at: job["enqueued_at"] ? Time.at(job["enqueued_at"]) : nil
            }
          },
          tags: {
            component: "sidekiq",
            queue: queue,
            worker: worker.class.name
          }
        )
      end

      def scrub_job_args(args)
        return args unless ActiveRabbit::Client.configuration.enable_pii_scrubbing
        return args unless args.is_a?(Array)

        PiiScrubber.new(ActiveRabbit::Client.configuration).scrub(args)
      end
    end

    # Auto-register the middleware if Sidekiq is available
    if defined?(Sidekiq)
      Sidekiq.configure_server do |config|
        config.server_middleware do |chain|
          chain.add ActiveRabbit::Client::SidekiqMiddleware
        end
      end
    end
  end
end
