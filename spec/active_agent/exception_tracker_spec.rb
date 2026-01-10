# frozen_string_literal: true

require "spec_helper"
require "active_rabbit/client/exception_tracker"
require "active_rabbit/client/configuration"
require "active_rabbit/client/http_client"

RSpec.describe ActiveRabbit::Client::ExceptionTracker do
  let(:configuration) do
    config = ActiveRabbit::Client::Configuration.new
    config.api_key = "test_api_key"
    config.api_url = "http://localhost:3000"
    config.environment = "test"
    config
  end

  let(:http_client) { instance_double(ActiveRabbit::Client::HttpClient) }
  let(:tracker) { described_class.new(configuration, http_client) }

  describe "#track_exception" do
    let(:exception) do
      begin
        raise ArgumentError, "Test error message"
      rescue => e
        e
      end
    end

    before do
      allow(http_client).to receive(:post_exception).and_return({ "status" => "ok" })
    end

    it "builds exception data with structured stack trace" do
      captured_data = nil
      allow(http_client).to receive(:post_exception) do |data|
        captured_data = data
        { "status" => "ok" }
      end

      tracker.track_exception(exception: exception)

      expect(captured_data).to include(:structured_stack_trace)
      expect(captured_data[:structured_stack_trace]).to be_an(Array)
      expect(captured_data[:structured_stack_trace].first).to include(
        :file, :line, :method, :in_app, :frame_type
      )
    end

    it "includes culprit_frame in exception data" do
      captured_data = nil
      allow(http_client).to receive(:post_exception) do |data|
        captured_data = data
        { "status" => "ok" }
      end

      tracker.track_exception(exception: exception)

      # The culprit_frame should be the first in-app frame
      expect(captured_data).to include(:culprit_frame)
    end

    it "preserves backward-compatible backtrace array" do
      captured_data = nil
      allow(http_client).to receive(:post_exception) do |data|
        captured_data = data
        { "status" => "ok" }
      end

      tracker.track_exception(exception: exception)

      expect(captured_data[:backtrace]).to be_an(Array)
      expect(captured_data[:backtrace]).to eq(exception.backtrace)
    end

    it "handles exception with nil backtrace" do
      exception_without_backtrace = ArgumentError.new("No backtrace")

      captured_data = nil
      allow(http_client).to receive(:post_exception) do |data|
        captured_data = data
        { "status" => "ok" }
      end

      # Should not raise
      expect {
        tracker.track_exception(exception: exception_without_backtrace)
      }.not_to raise_error

      expect(captured_data[:structured_stack_trace]).to eq([])
    end

    it "includes required fields" do
      captured_data = nil
      allow(http_client).to receive(:post_exception) do |data|
        captured_data = data
        { "status" => "ok" }
      end

      tracker.track_exception(exception: exception)

      expect(captured_data[:exception_class]).to eq("ArgumentError")
      expect(captured_data[:message]).to eq("Test error message")
      expect(captured_data[:backtrace]).to be_an(Array)
      expect(captured_data[:backtrace]).not_to be_empty
      expect(captured_data[:occurred_at]).not_to be_nil
      expect(captured_data[:environment]).to eq("test")
    end
  end

  describe "structured frame format" do
    it "creates frames with expected structure" do
      exception = begin
        raise StandardError, "Test"
      rescue => e
        e
      end

      captured_data = nil
      allow(http_client).to receive(:post_exception) do |data|
        captured_data = data
        { "status" => "ok" }
      end

      tracker.track_exception(exception: exception)

      frame = captured_data[:structured_stack_trace].first
      expect(frame).to have_key(:file)
      expect(frame).to have_key(:line)
      expect(frame).to have_key(:method)
      expect(frame).to have_key(:raw)
      expect(frame).to have_key(:in_app)
      expect(frame).to have_key(:frame_type)
      expect(frame).to have_key(:index)
      expect(frame).to have_key(:source_context)
    end
  end

  describe "#extract_relevant_backtrace_for_fingerprint" do
    it "handles backtrace with nil entries" do
      # Access private method for testing
      tracker_instance = tracker

      backtrace_with_nils = [
        "app/controllers/test.rb:1:in `test'",
        nil,
        "app/models/user.rb:5:in `save'",
        nil
      ]

      # Should not raise
      result = tracker_instance.send(:extract_relevant_backtrace_for_fingerprint, backtrace_with_nils)
      expect(result).to be_a(String)
    end

    it "handles completely nil backtrace" do
      tracker_instance = tracker
      result = tracker_instance.send(:extract_relevant_backtrace_for_fingerprint, nil)
      expect(result).to eq("")
    end
  end
end
