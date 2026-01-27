# frozen_string_literal: true

return unless defined?(ActionMailer)

module ActiveRabbit
  module Client
    module ActionMailerPatch
      def deliver_now
        start_time = Time.now
        super
      ensure
        if ActiveRabbit::Client.configured?
          duration_ms = ((Time.now - start_time) * 1000).round(2)
          ActiveRabbit::Client.track_event(
            "email_sent",
            {
              mailer_class: @mailer_class.name,
              action: @action,
              message_id: (message.message_id rescue nil),
              subject: (message.subject rescue nil),
              to: (Array(message.to).first rescue nil),
              duration_ms: duration_ms
            }
          )
        end
      end

      def deliver_later(...)
        # IMPORTANT: Do NOT access `message` here!
        # Rails raises RuntimeError if you access the message before deliver_later
        # because only mailer method arguments are passed to the job.
        # We can only safely access metadata that doesn't touch the message object.
        if ActiveRabbit::Client.configured?
          begin
            ActiveRabbit::Client.track_event(
              "email_enqueued",
              {
                mailer_class: @mailer_class.name,
                action: @action,
                args: @args&.map { |a| a.class.name }
              }
            )
          rescue => e
            # Don't let tracking failures break email delivery
            Rails.logger.error "[ActiveRabbit] Failed to track email_enqueued: #{e.message}" if defined?(Rails) && Rails.logger
          end
        end
        super
      end
    end
  end
end

ActionMailer::MessageDelivery.prepend(ActiveRabbit::Client::ActionMailerPatch)


