# frozen_string_literal: true

module ActiveRabbit
  module Client
    module ActiveJobExtensions
      def self.included(base)
        base.around_perform do |job, block|
          start_time = Time.now

          Thread.current[:active_rabbit_job_context] = {
            job_class: job.class.name,
            job_id: job.job_id,
            queue_name: job.queue_name,
            arguments: ActiveRabbit::Client::ActiveJobExtensions.scrub_arguments(job.arguments),
            provider_job_id: (job.respond_to?(:provider_job_id) ? job.provider_job_id : nil)
          }

          begin
            block.call

            duration_ms = ((Time.now - start_time) * 1000).round(2)
            if ActiveRabbit::Client.configured?
              ActiveRabbit::Client.track_performance(
                "active_job.perform",
                duration_ms,
                metadata: { job_class: job.class.name, queue_name: job.queue_name, status: "completed" }
              )
            end
          rescue Exception => exception
            duration_ms = ((Time.now - start_time) * 1000).round(2)
            if ActiveRabbit::Client.configured?
              ActiveRabbit::Client.track_performance(
                "active_job.perform",
                duration_ms,
                metadata: { job_class: job.class.name, queue_name: job.queue_name, status: "failed" }
              )

              ActiveRabbit::Client.track_exception(
                exception,
                context: {
                  job: {
                    job_class: job.class.name,
                    job_id: job.job_id,
                    queue_name: job.queue_name,
                    arguments: ActiveRabbit::Client::ActiveJobExtensions.scrub_arguments(job.arguments)
                  }
                },
                tags: { component: "active_job", queue: job.queue_name }
              )
            end
            raise
          ensure
            Thread.current[:active_rabbit_job_context] = nil
          end
        end
      end

      def self.scrub_arguments(args)
        return args unless ActiveRabbit::Client.configuration&.enable_pii_scrubbing
        PiiScrubber.new(ActiveRabbit::Client.configuration).scrub(args)
      end
    end
  end
end


