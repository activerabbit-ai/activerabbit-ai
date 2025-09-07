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
        req_id = context[:request]&.[](:request_id) || context[:request_id] || context[:requestId]
        [exception.class.name, top, req_id].join("|")
      end
    end
  end
end


