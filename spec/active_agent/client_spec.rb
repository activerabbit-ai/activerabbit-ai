# frozen_string_literal: true

RSpec.describe ActiveAgent::Client do
  let(:api_key) { "test-api-key" }
  let(:project_id) { "test-project-id" }

  before do
    # Reset configuration before each test
    ActiveAgent::Client.configuration = nil

    # Clear any cached instances
    ActiveAgent::Client.instance_variable_set(:@event_processor, nil)
    ActiveAgent::Client.instance_variable_set(:@exception_tracker, nil)
    ActiveAgent::Client.instance_variable_set(:@performance_monitor, nil)
    ActiveAgent::Client.instance_variable_set(:@http_client, nil)
  end

  after do
    # Clean up after each test
    ActiveAgent::Client.configuration = nil

    # Clear any cached instances
    ActiveAgent::Client.instance_variable_set(:@event_processor, nil)
    ActiveAgent::Client.instance_variable_set(:@exception_tracker, nil)
    ActiveAgent::Client.instance_variable_set(:@performance_monitor, nil)
    ActiveAgent::Client.instance_variable_set(:@http_client, nil)
  end

  describe "VERSION" do
    it "has a version number" do
      expect(ActiveAgent::Client::VERSION).not_to be nil
      expect(ActiveAgent::Client::VERSION).to match(/\d+\.\d+\.\d+/)
    end
  end

  describe ".configure" do
    it "yields a configuration object" do
      expect { |b| ActiveAgent::Client.configure(&b) }.to yield_with_args(ActiveAgent::Client::Configuration)
    end

    it "sets the configuration" do
      ActiveAgent::Client.configure do |config|
        config.api_key = api_key
        config.project_id = project_id
      end

      expect(ActiveAgent::Client.configuration.api_key).to eq(api_key)
      expect(ActiveAgent::Client.configuration.project_id).to eq(project_id)
    end

    it "returns the configuration" do
      config = ActiveAgent::Client.configure do |c|
        c.api_key = api_key
      end

      expect(config).to be_a(ActiveAgent::Client::Configuration)
      expect(config.api_key).to eq(api_key)
    end
  end

  describe ".configured?" do
    context "when not configured" do
      it "returns false" do
        expect(ActiveAgent::Client.configured?).to be false
      end
    end

    context "when configured with API key" do
      before do
        ActiveAgent::Client.configure do |config|
          config.api_key = api_key
        end
      end

      it "returns true" do
        expect(ActiveAgent::Client.configured?).to be true
      end
    end

    context "when configured with empty API key" do
      before do
        ActiveAgent::Client.configure do |config|
          config.api_key = ""
        end
      end

      it "returns false" do
        expect(ActiveAgent::Client.configured?).to be false
      end
    end
  end

  describe ".track_event" do
    let(:event_processor) { instance_double(ActiveAgent::Client::EventProcessor) }

    before do
      ActiveAgent::Client.configure do |config|
        config.api_key = api_key
        config.project_id = project_id
      end

      allow(ActiveAgent::Client::EventProcessor).to receive(:new).and_return(event_processor)
    end

    it "calls the event processor when configured" do
      expect(event_processor).to receive(:track_event).with(
        name: "test_event",
        properties: { key: "value" },
        user_id: "user123",
        timestamp: kind_of(Time)
      )

      ActiveAgent::Client.track_event(
        "test_event",
        { key: "value" },
        user_id: "user123"
      )
    end

    it "does nothing when not configured" do
      ActiveAgent::Client.configuration = nil

      expect(ActiveAgent::Client::EventProcessor).not_to receive(:new)

      ActiveAgent::Client.track_event("test_event", {})
    end
  end

  describe ".track_exception" do
    let(:exception_tracker) { instance_double(ActiveAgent::Client::ExceptionTracker) }
    let(:exception) { StandardError.new("Test error") }

    before do
      ActiveAgent::Client.configure do |config|
        config.api_key = api_key
        config.project_id = project_id
      end

      allow(ActiveAgent::Client::ExceptionTracker).to receive(:new).and_return(exception_tracker)
    end

    it "calls the exception tracker when configured" do
      expect(exception_tracker).to receive(:track_exception).with(
        exception: exception,
        context: { key: "value" },
        user_id: "user123",
        tags: { component: "test" }
      )

      ActiveAgent::Client.track_exception(
        exception,
        context: { key: "value" },
        user_id: "user123",
        tags: { component: "test" }
      )
    end

    it "does nothing when not configured" do
      ActiveAgent::Client.configuration = nil

      expect(ActiveAgent::Client::ExceptionTracker).not_to receive(:new)

      ActiveAgent::Client.track_exception(exception)
    end
  end

  describe ".track_performance" do
    let(:performance_monitor) { instance_double(ActiveAgent::Client::PerformanceMonitor) }

    before do
      ActiveAgent::Client.configure do |config|
        config.api_key = api_key
        config.project_id = project_id
      end

      allow(ActiveAgent::Client::PerformanceMonitor).to receive(:new).and_return(performance_monitor)
    end

    it "calls the performance monitor when configured" do
      expect(performance_monitor).to receive(:track_performance).with(
        name: "test_operation",
        duration_ms: 1500.0,
        metadata: { key: "value" }
      )

      ActiveAgent::Client.track_performance(
        "test_operation",
        1500.0,
        metadata: { key: "value" }
      )
    end

    it "does nothing when not configured" do
      ActiveAgent::Client.configuration = nil

      expect(ActiveAgent::Client::PerformanceMonitor).not_to receive(:new)

      ActiveAgent::Client.track_performance("test_operation", 1500.0)
    end
  end

  describe ".flush" do
    let(:event_processor) { instance_double(ActiveAgent::Client::EventProcessor) }
    let(:exception_tracker) { instance_double(ActiveAgent::Client::ExceptionTracker) }
    let(:performance_monitor) { instance_double(ActiveAgent::Client::PerformanceMonitor) }

    before do
      ActiveAgent::Client.configure do |config|
        config.api_key = api_key
        config.project_id = project_id
      end

      allow(ActiveAgent::Client::EventProcessor).to receive(:new).and_return(event_processor)
      allow(ActiveAgent::Client::ExceptionTracker).to receive(:new).and_return(exception_tracker)
      allow(ActiveAgent::Client::PerformanceMonitor).to receive(:new).and_return(performance_monitor)
    end

    it "flushes all components when configured" do
      expect(event_processor).to receive(:flush)
      expect(exception_tracker).to receive(:flush)
      expect(performance_monitor).to receive(:flush)

      ActiveAgent::Client.flush
    end

    it "does nothing when not configured" do
      ActiveAgent::Client.configuration = nil

      expect(ActiveAgent::Client::EventProcessor).not_to receive(:new)

      ActiveAgent::Client.flush
    end
  end

    describe ".shutdown" do
    let(:event_processor) { instance_double(ActiveAgent::Client::EventProcessor) }
    let(:exception_tracker) { instance_double(ActiveAgent::Client::ExceptionTracker) }
    let(:performance_monitor) { instance_double(ActiveAgent::Client::PerformanceMonitor) }
    let(:http_client) { instance_double(ActiveAgent::Client::HttpClient) }

    before do
      ActiveAgent::Client.configure do |config|
        config.api_key = api_key
        config.project_id = project_id
      end

      allow(ActiveAgent::Client::EventProcessor).to receive(:new).and_return(event_processor)
      allow(ActiveAgent::Client::ExceptionTracker).to receive(:new).and_return(exception_tracker)
      allow(ActiveAgent::Client::PerformanceMonitor).to receive(:new).and_return(performance_monitor)
      allow(ActiveAgent::Client::HttpClient).to receive(:new).and_return(http_client)
    end

    it "shuts down all components when configured" do
      # First call flush
      expect(event_processor).to receive(:flush)
      expect(exception_tracker).to receive(:flush)
      expect(performance_monitor).to receive(:flush)

      # Then shutdown components
      expect(event_processor).to receive(:shutdown)
      expect(http_client).to receive(:shutdown)

      ActiveAgent::Client.shutdown
    end

    it "does nothing when not configured" do
      ActiveAgent::Client.configuration = nil

      expect(ActiveAgent::Client::EventProcessor).not_to receive(:new)

      ActiveAgent::Client.shutdown
    end
  end
end
