# frozen_string_literal: true

module ActiveAgent
  module Client
    class NPlusOneDetector
      attr_reader :configuration

      def initialize(configuration)
        @configuration = configuration
        @query_patterns = Concurrent::Hash.new { |h, k| h[k] = [] }
        @request_queries = Concurrent::Hash.new { |h, k| h[k] = [] }
      end

      def track_query(sql, bindings = nil, name = nil, duration = nil)
        return unless configuration.enable_n_plus_one_detection
        return unless current_request_id

        query_info = {
          sql: normalize_sql(sql),
          bindings: bindings,
          name: name,
          duration: duration,
          timestamp: Time.current,
          backtrace: caller(2, 10) # Skip this method and the AR method
        }

        @request_queries[current_request_id] << query_info
      end

      def analyze_request_queries(request_id = nil)
        request_id ||= current_request_id
        return unless request_id

        queries = @request_queries.delete(request_id) || []
        return if queries.empty?

        n_plus_one_issues = detect_n_plus_one_patterns(queries)

        n_plus_one_issues.each do |issue|
          report_n_plus_one_issue(issue)
        end
      end

      def start_request(request_id = nil)
        request_id ||= SecureRandom.uuid
        Thread.current[:active_agent_request_id] = request_id
        @request_queries[request_id] = []
        request_id
      end

      def finish_request(request_id = nil)
        request_id ||= current_request_id
        return unless request_id

        analyze_request_queries(request_id)
        Thread.current[:active_agent_request_id] = nil
      end

      private

      def current_request_id
        Thread.current[:active_agent_request_id]
      end

      def normalize_sql(sql)
        return sql unless sql.is_a?(String)

        # Remove specific values to group similar queries
        normalized = sql.dup

        # Replace string literals
        normalized.gsub!(/'[^']*'/, '?')
        normalized.gsub!(/"[^"]*"/, '?')

        # Replace numbers
        normalized.gsub(/\b\d+\b/, '?')

        # Replace IN clauses with multiple values
        normalized.gsub(/IN\s*\([^)]*\)/i, 'IN (?)')

        # Normalize whitespace
        normalized.gsub(/\s+/, ' ').strip
      end

      def detect_n_plus_one_patterns(queries)
        issues = []

        # Group queries by normalized SQL
        grouped_queries = queries.group_by { |q| q[:sql] }

        grouped_queries.each do |normalized_sql, query_group|
          next if query_group.size < 3 # Need at least 3 similar queries to consider N+1

          # Check if queries are executed in quick succession
          if queries_in_quick_succession?(query_group)
            issues << build_n_plus_one_issue(normalized_sql, query_group)
          end
        end

        issues
      end

      def queries_in_quick_succession?(query_group)
        return false if query_group.size < 2

        # Check if queries are within a short time window (1 second)
        first_query_time = query_group.first[:timestamp]
        last_query_time = query_group.last[:timestamp]

        (last_query_time - first_query_time) < 1.0
      end

      def build_n_plus_one_issue(normalized_sql, query_group)
        # Find the most common backtrace pattern
        backtrace_patterns = query_group.map { |q| extract_app_backtrace(q[:backtrace]) }
        common_backtrace = find_most_common_backtrace(backtrace_patterns)

        total_duration = query_group.sum { |q| q[:duration] || 0 }

        {
          type: "n_plus_one_query",
          normalized_sql: normalized_sql,
          query_count: query_group.size,
          total_duration_ms: total_duration,
          average_duration_ms: total_duration / query_group.size,
          backtrace: common_backtrace,
          first_query_time: query_group.first[:timestamp],
          last_query_time: query_group.last[:timestamp],
          sample_bindings: query_group.first(3).map { |q| q[:bindings] }.compact
        }
      end

      def extract_app_backtrace(backtrace)
        return [] unless backtrace

        # Only include application code, not gems or stdlib
        app_root = defined?(Rails) ? Rails.root.to_s : Dir.pwd

        backtrace.select do |line|
          line.start_with?(app_root) && !line.include?('/vendor/') && !line.include?('/gems/')
        end.first(5) # Limit to first 5 app frames
      end

      def find_most_common_backtrace(backtrace_patterns)
        return [] if backtrace_patterns.empty?

        # Find the backtrace pattern that appears most frequently
        backtrace_counts = backtrace_patterns.each_with_object(Hash.new(0)) do |backtrace, counts|
          key = backtrace.join("|")
          counts[key] += 1
        end

        most_common_key = backtrace_counts.max_by { |_, count| count }&.first
        return [] unless most_common_key

        most_common_key.split("|")
      end

      def report_n_plus_one_issue(issue)
        # Create a structured exception for the N+1 issue
        exception_data = {
          type: "NPlusOneQueryIssue",
          message: "N+1 query detected: #{issue[:query_count]} similar queries executed",
          details: issue,
          timestamp: Time.current.iso8601(3),
          environment: configuration.environment,
          release: configuration.release,
          server_name: configuration.server_name
        }

        exception_data[:project_id] = configuration.project_id if configuration.project_id

        # Send as a performance issue rather than an exception
        Client.track_event(
          "n_plus_one_detected",
          {
            normalized_sql: issue[:normalized_sql],
            query_count: issue[:query_count],
            total_duration_ms: issue[:total_duration_ms],
            average_duration_ms: issue[:average_duration_ms]
          }
        )
      end
    end
  end
end
