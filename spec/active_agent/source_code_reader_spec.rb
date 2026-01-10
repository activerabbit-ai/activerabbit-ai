# frozen_string_literal: true

require "spec_helper"
require "active_rabbit/client/source_code_reader"
require "tempfile"

RSpec.describe ActiveRabbit::Client::SourceCodeReader do
  describe ".read_context" do
    let(:temp_file) do
      file = Tempfile.new(["test_source", ".rb"])
      file.write(<<~RUBY)
        # Line 1: Comment
        def hello
          puts "Hello"
          x = 1 + 2
          raise "Error here"
          puts "After error"
        end
        # Line 8: End
      RUBY
      file.close
      file
    end

    after { temp_file.unlink }

    it "returns source context around the specified line" do
      result = described_class.read_context(temp_file.path, 5, context_lines: 2)

      expect(result).to be_a(Hash)
      expect(result[:lines_before]).to eq(["  puts \"Hello\"", "  x = 1 + 2"])
      expect(result[:line_content]).to eq("  raise \"Error here\"")
      expect(result[:lines_after]).to eq(["  puts \"After error\"", "end"])
      expect(result[:start_line]).to eq(3)
    end

    it "handles line at the beginning of file" do
      result = described_class.read_context(temp_file.path, 1, context_lines: 2)

      expect(result).to be_a(Hash)
      expect(result[:lines_before]).to eq([])
      expect(result[:line_content]).to eq("# Line 1: Comment")
      expect(result[:start_line]).to eq(1)
    end

    it "handles line at the end of file" do
      result = described_class.read_context(temp_file.path, 8, context_lines: 2)

      expect(result).to be_a(Hash)
      expect(result[:line_content]).to eq("# Line 8: End")
      expect(result[:lines_after]).to eq([])
    end

    it "returns nil for non-existent file" do
      result = described_class.read_context("/non/existent/file.rb", 5)
      expect(result).to be_nil
    end

    it "returns nil for nil file path" do
      result = described_class.read_context(nil, 5)
      expect(result).to be_nil
    end

    it "returns nil for invalid line number" do
      expect(described_class.read_context(temp_file.path, 0)).to be_nil
      expect(described_class.read_context(temp_file.path, -1)).to be_nil
      expect(described_class.read_context(temp_file.path, 1000)).to be_nil
    end

    it "truncates very long lines" do
      long_line_file = Tempfile.new(["long_line", ".rb"])
      long_line_file.write("x" * 600)
      long_line_file.close

      result = described_class.read_context(long_line_file.path, 1)
      expect(result[:line_content].length).to be <= 503 # MAX_LINE_LENGTH + "..."

      long_line_file.unlink
    end
  end

  describe ".parse_backtrace_with_source" do
    it "parses backtrace frames into structured data" do
      backtrace = [
        "app/controllers/users_controller.rb:25:in `show'",
        "/home/user/.gems/rails-7.0/action_controller.rb:100:in `process'"
      ]

      frames = described_class.parse_backtrace_with_source(backtrace, context_lines: 0)

      expect(frames.length).to eq(2)

      expect(frames[0][:file]).to eq("app/controllers/users_controller.rb")
      expect(frames[0][:line]).to eq(25)
      expect(frames[0][:method]).to eq("show")
      expect(frames[0][:in_app]).to be true
      expect(frames[0][:frame_type]).to eq(:controller)

      expect(frames[1][:file]).to eq("/home/user/.gems/rails-7.0/action_controller.rb")
      expect(frames[1][:in_app]).to be false
      expect(frames[1][:frame_type]).to eq(:gem)
    end

    it "handles empty backtrace" do
      expect(described_class.parse_backtrace_with_source([])).to eq([])
      expect(described_class.parse_backtrace_with_source(nil)).to eq([])
    end

    it "handles string backtrace (newline separated)" do
      backtrace = "app/models/user.rb:10:in `save'\nlib/validator.rb:5:in `validate'"

      frames = described_class.parse_backtrace_with_source(backtrace, context_lines: 0)

      expect(frames.length).to eq(2)
      expect(frames[0][:file]).to eq("app/models/user.rb")
      expect(frames[1][:file]).to eq("lib/validator.rb")
    end
  end

  describe ".parse_frame_with_source" do
    it "parses standard Ruby backtrace format" do
      frame = described_class.parse_frame_with_source(
        "app/services/payment_service.rb:42:in `process_payment'",
        0,
        context_lines: 0
      )

      expect(frame[:file]).to eq("app/services/payment_service.rb")
      expect(frame[:line]).to eq(42)
      expect(frame[:method]).to eq("process_payment")
      expect(frame[:in_app]).to be true
      expect(frame[:frame_type]).to eq(:service)
      expect(frame[:index]).to eq(0)
    end

    it "parses frame with block notation" do
      frame = described_class.parse_frame_with_source(
        "app/jobs/sync_job.rb:15:in `block in perform'",
        1,
        context_lines: 0
      )

      expect(frame[:method]).to eq("block in perform")
      expect(frame[:frame_type]).to eq(:job)
    end

    it "handles malformed frame gracefully" do
      frame = described_class.parse_frame_with_source("some random text", 0, context_lines: 0)

      expect(frame[:file]).to be_nil
      expect(frame[:line]).to be_nil
      expect(frame[:method]).to be_nil
      expect(frame[:raw]).to eq("some random text")
      expect(frame[:in_app]).to be false
      expect(frame[:frame_type]).to eq(:unknown)
    end

    it "returns nil for blank frame" do
      expect(described_class.parse_frame_with_source("", 0)).to be_nil
      expect(described_class.parse_frame_with_source(nil, 0)).to be_nil
      expect(described_class.parse_frame_with_source("   ", 0)).to be_nil
    end
  end

  describe "frame classification" do
    # Test in-app frames - classification matches in order:
    # controllers, models, services, jobs, views, helpers, mailers, concerns, lib/, gems
    {
      "app/controllers/users_controller.rb" => [:controller, true],
      "app/models/user.rb" => [:model, true],
      "app/services/payment_service.rb" => [:service, true],
      "app/jobs/sync_job.rb" => [:job, true],
      "app/views/users/show.html.erb" => [:view, true],
      "app/helpers/application_helper.rb" => [:helper, true],
      "app/mailers/user_mailer.rb" => [:mailer, true],
      # Note: concerns in app/models/concerns/ matches 'models' first
      "app/models/concerns/authenticatable.rb" => [:model, true],
      # Pure concerns path matches concern
      "app/concerns/authenticatable.rb" => [:concern, true],
      "lib/custom_validator.rb" => [:library, true]
    }.each do |file, (expected_type, expected_in_app)|
      it "classifies #{file} as #{expected_type}, in_app=#{expected_in_app}" do
        frame = described_class.parse_frame_with_source("#{file}:1:in `test'", 0, context_lines: 0)
        expect(frame[:frame_type]).to eq(expected_type)
        expect(frame[:in_app]).to eq(expected_in_app)
      end
    end

    # Test non-app frames (gems, ruby stdlib)
    # Note: paths with /lib/ match :library before :gem
    {
      "/path/to/gems/rails-7.0.0/action_controller.rb" => [:gem, false],
      # Ruby stdlib with lib/ matches :library
      "/usr/lib/ruby/3.2.0/net/http.rb" => [:library, false]
    }.each do |file, (expected_type, expected_in_app)|
      it "classifies #{file} as #{expected_type}, in_app=#{expected_in_app}" do
        frame = described_class.parse_frame_with_source("#{file}:1:in `test'", 0, context_lines: 0)
        expect(frame[:frame_type]).to eq(expected_type)
        expect(frame[:in_app]).to eq(expected_in_app)
      end
    end
  end
end
