# frozen_string_literal: true

require "monitor"

module ActiveRabbit
  module Client
    module Dedupe
      extend self

      WINDOW_SECONDS = 5

      @seen = {}
      @lock = Monitor.new

      def seen_recently?(exception, context = {}, window: WINDOW_SECONDS)
        key = build_key(exception, context)
        now = Time.now.to_f
        @lock.synchronize do
          prune!(now, window)
          last = @seen[key]
          @seen[key] = now
          return last && (now - last) < window
        end
      end

      private

      def prune!(now, window)
        cutoff = now - window
        @seen.delete_if { |_k, ts| ts < cutoff }
      end

      def build_key(exception, context)
        top = Array(exception.backtrace).first.to_s
        ctx = context.is_a?(Hash) ? context : {}
        req = ctx[:request] || ctx["request"]
        req_hash = req.is_a?(Hash) ? req : {}

        req_id =
          req_hash[:request_id] || req_hash["request_id"] ||
          req_hash[:requestId] || req_hash["requestId"] ||
          ctx[:request_id] || ctx["request_id"] ||
          ctx[:requestId] || ctx["requestId"]

        [exception.class.name, top, req_id].join("|")
      end
    end
  end
end


