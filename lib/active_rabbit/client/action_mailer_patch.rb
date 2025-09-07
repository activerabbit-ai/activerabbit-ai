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
              mailer: self.class.name,
              message_id: (message.message_id rescue nil),
              subject: (message.subject rescue nil),
              to: (Array(message.to).first rescue nil),
              duration_ms: duration_ms
            }
          )
        end
      end

      def deliver_later
        ActiveRabbit::Client.track_event(
          "email_enqueued",
          { mailer: self.class.name, subject: (message.subject rescue nil), to: (Array(message.to).first rescue nil) }
        ) if ActiveRabbit::Client.configured?
        super
      end
    end
  end
end

ActionMailer::MessageDelivery.prepend(ActiveRabbit::Client::ActionMailerPatch)


