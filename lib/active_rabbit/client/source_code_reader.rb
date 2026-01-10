# frozen_string_literal: true

module ActiveRabbit
  module Client
    # Reads source code context around error lines for rich stack traces
    # Similar to how Sentry captures source context at error time
    class SourceCodeReader
      DEFAULT_CONTEXT_LINES = 5
      MAX_LINE_LENGTH = 500

      class << self
        # Read source code context for a specific file and line
        # Returns nil if file cannot be read
        def read_context(file_path, line_number, context_lines: DEFAULT_CONTEXT_LINES)
          return nil if blank?(file_path) || line_number.nil? || line_number < 1

          # Resolve to absolute path
          full_path = resolve_path(file_path)
          return nil unless full_path && File.exist?(full_path) && File.readable?(full_path)

          # Skip binary files and very large files
          return nil if binary_file?(full_path)
          return nil if File.size(full_path) > 1_000_000 # Skip files > 1MB

          begin
            lines = File.readlines(full_path)
            total_lines = lines.length

            return nil if line_number > total_lines

            # Calculate range (0-indexed internally)
            start_idx = [line_number - context_lines - 1, 0].max
            end_idx = [line_number + context_lines - 1, total_lines - 1].min

            # Build context structure
            lines_before = []
            (start_idx...(line_number - 1)).each do |i|
              lines_before << truncate_line(lines[i]&.chomp || "")
            end

            line_content = truncate_line(lines[line_number - 1]&.chomp || "")

            lines_after = []
            (line_number..end_idx).each do |i|
              lines_after << truncate_line(lines[i]&.chomp || "")
            end

            {
              lines_before: lines_before,
              line_content: line_content,
              lines_after: lines_after,
              start_line: start_idx + 1
            }
          rescue StandardError => e
            # Log but don't fail
            if defined?(Rails.logger)
              Rails.logger.debug "[ActiveRabbit] Could not read source for #{file_path}: #{e.message}"
            end
            nil
          end
        end

        # Parse a backtrace and add source context to each frame
        def parse_backtrace_with_source(backtrace, context_lines: DEFAULT_CONTEXT_LINES)
          return [] if blank?(backtrace)

          frames = backtrace.is_a?(Array) ? backtrace : backtrace.split("\n")

          frames.map.with_index do |frame_line, index|
            parse_frame_with_source(frame_line, index, context_lines: context_lines)
          end.compact
        end

        # Parse a single frame and add source context
        def parse_frame_with_source(frame_line, index = 0, context_lines: DEFAULT_CONTEXT_LINES)
          return nil if blank?(frame_line)

          # Parse frame: "path/to/file.rb:123:in `method_name'"
          pattern = /^(.+?):(\d+)(?::in [`'](.+?)'?)?\s*$/

          if (match = frame_line.match(pattern))
            file = match[1]
            line = match[2].to_i
            method_name = match[3]

            in_app = in_app_frame?(file)
            frame_type = classify_frame(file)

            # Only read source for in-app frames to save bandwidth
            source_context = if in_app
                               read_context(file, line, context_lines: context_lines)
                             end

            {
              file: file,
              line: line,
              method: method_name,
              raw: frame_line,
              in_app: in_app,
              frame_type: frame_type,
              index: index,
              source_context: source_context
            }
          else
            # Fallback for non-standard frame formats
            {
              file: nil,
              line: nil,
              method: nil,
              raw: frame_line,
              in_app: false,
              frame_type: :unknown,
              index: index,
              source_context: nil
            }
          end
        end

        private

        # Helper to check for blank values (works without Rails)
        def blank?(value)
          value.nil? || (value.respond_to?(:empty?) && value.empty?) || (value.is_a?(String) && value.strip.empty?)
        end

        def resolve_path(file_path)
          return nil if blank?(file_path)

          # Already absolute
          if file_path.start_with?("/")
            return file_path if File.exist?(file_path)
          end

          # Try relative to Rails root
          if defined?(Rails) && Rails.respond_to?(:root) && Rails.root
            full_path = Rails.root.join(file_path)
            return full_path.to_s if File.exist?(full_path)
          end

          # Try relative to current directory
          if File.exist?(file_path)
            return File.expand_path(file_path)
          end

          # Try common app paths
          ["app/", "lib/", "config/"].each do |prefix|
            if file_path.start_with?(prefix) && defined?(Rails) && Rails.root
              full_path = Rails.root.join(file_path)
              return full_path.to_s if File.exist?(full_path)
            end
          end

          nil
        end

        def in_app_frame?(file)
          return false if blank?(file)

          # In-app if it's in app/, lib/, or similar app directories
          # and NOT in gems or ruby stdlib
          (file.start_with?("app/") ||
           file.start_with?("lib/") ||
           file.start_with?("config/") ||
           (file.include?("/app/") && !file.include?("/gems/"))) &&
            !file.include?("/gems/") &&
            !file.include?("/ruby/") &&
            !file.include?("/rubygems/") &&
            !file.include?("/.bundle/")
        end

        def classify_frame(file)
          return :unknown if blank?(file)

          case file
          when /controllers/ then :controller
          when /models/ then :model
          when /services/ then :service
          when /jobs/ then :job
          when /views/ then :view
          when /helpers/ then :helper
          when /mailers/ then :mailer
          when /concerns/ then :concern
          when /lib\// then :library
          when /gems?[\/\\]/ then :gem
          else :other
          end
        end

        def binary_file?(path)
          # Check first few bytes for binary content
          File.open(path, "rb") do |f|
            bytes = f.read(512)
            return false if bytes.nil? || bytes.empty?
            # If more than 30% are non-printable, consider binary
            non_printable = bytes.bytes.count { |b| b < 32 && ![9, 10, 13].include?(b) }
            (non_printable.to_f / bytes.length) > 0.3
          end
        rescue StandardError
          false
        end

        def truncate_line(line)
          return "" if line.nil?
          line.length > MAX_LINE_LENGTH ? line[0, MAX_LINE_LENGTH] + "..." : line
        end
      end
    end
  end
end
