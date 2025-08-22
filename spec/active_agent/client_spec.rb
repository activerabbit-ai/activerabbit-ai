# frozen_string_literal: true

RSpec.describe ActiveRabbit::Client do
  let(:api_key) { "test-api-key" }
  let(:project_id) { "test-project-id" }

  before do
    # Reset configuration before each test
    ActiveRabbit::Client.configuration = nil

    # Clear any cached instances
    ActiveRabbit::Client.instance_variable_set(:@event_processor, nil)
    ActiveRabbit::Client.instance_variable_set(:@exception_tracker, nil)
    ActiveRabbit::Client.instance_variable_set(:@performance_monitor, nil)
    ActiveRabbit::Client.instance_variable_set(:@http_client, nil)
  end

  after do
    # Clean up after each test
    ActiveRabbit::Client.configuration = nil

    # Clear any cached instances
    ActiveRabbit::Client.instance_variable_set(:@event_processor, nil)
    ActiveRabbit::Client.instance_variable_set(:@exception_tracker, nil)
    ActiveRabbit::Client.instance_variable_set(:@performance_monitor, nil)
    ActiveRabbit::Client.instance_variable_set(:@http_client, nil)
  end

  describe "VERSION" do
    it "has a version number" do
      expect(ActiveRabbit::Client::VERSION).not_to be nil
      expect(ActiveRabbit::Client::VERSION).to match(/\d+\.\d+\.\d+/)
    end
  end

  describe ".configure" do
    it "yields a configuration object" do
      expect { |b| ActiveRabbit::Client.configure(&b) }.to yield_with_args(ActiveRabbit::Client::Configuration)
    end

    it "sets the configuration" do
      ActiveRabbit::Client.configure do |config|
        config.api_key = api_key
        config.project_id = project_id
      end

      expect(ActiveRabbit::Client.configuration.api_key).to eq(api_key)
      expect(ActiveRabbit::Client.configuration.project_id).to eq(project_id)
    end

    it "returns the configuration" do
      config = ActiveRabbit::Client.configure do |c|
        c.api_key = api_key
      end

      expect(config).to be_a(ActiveRabbit::Client::Configuration)
      expect(config.api_key).to eq(api_key)
    end
  end

  describe ".configured?" do
    context "when not configured" do
      it "returns false" do
        expect(ActiveRabbit::Client.configured?).to be false
      end
    end

    context "when configured with API key" do
      before do
        ActiveRabbit::Client.configure do |config|
          config.api_key = api_key
        end
      end

      it "returns true" do
        expect(ActiveRabbit::Client.configured?).to be true
      end
    end

    context "when configured with empty API key" do
      before do
        ActiveRabbit::Client.configure do |config|
          config.api_key = ""
        end
      end

      it "returns false" do
        expect(ActiveRabbit::Client.configured?).to be false
      end
    end
  end

  describe ".track_event" do
    let(:event_processor) { instance_double(ActiveRabbit::Client::EventProcessor) }

    before do
      ActiveRabbit::Client.configure do |config|
        config.api_key = api_key
        config.project_id = project_id
      end

      allow(ActiveRabbit::Client::EventProcessor).to receive(:new).and_return(event_processor)
    end

    it "calls the event processor when configured" do
      expect(event_processor).to receive(:track_event).with(
        name: "test_event",
        properties: { key: "value" },
        user_id: "user123",
        timestamp: kind_of(Time)
      )

      ActiveRabbit::Client.track_event(
        "test_event",
        { key: "value" },
        user_id: "user123"
      )
    end

    it "does nothing when not configured" do
      ActiveRabbit::Client.configuration = nil

      expect(ActiveRabbit::Client::EventProcessor).not_to receive(:new)

      ActiveRabbit::Client.track_event("test_event", {})
    end
  end

  describe ".track_exception" do
    let(:exception_tracker) { instance_double(ActiveRabbit::Client::ExceptionTracker) }
    let(:exception) { StandardError.new("Test error") }

    before do
      ActiveRabbit::Client.configure do |config|
        config.api_key = api_key
        config.project_id = project_id
      end

      allow(ActiveRabbit::Client::ExceptionTracker).to receive(:new).and_return(exception_tracker)
    end

    it "calls the exception tracker when configured" do
      expect(exception_tracker).to receive(:track_exception).with(
        exception: exception,
        context: { key: "value" },
        user_id: "user123",
        tags: { component: "test" }
      )

      ActiveRabbit::Client.track_exception(
        exception,
        context: { key: "value" },
        user_id: "user123",
        tags: { component: "test" }
      )
    end

    it "does nothing when not configured" do
      ActiveRabbit::Client.configuration = nil

      expect(ActiveRabbit::Client::ExceptionTracker).not_to receive(:new)

      ActiveRabbit::Client.track_exception(exception)
    end
  end

  describe ".track_performance" do
    let(:performance_monitor) { instance_double(ActiveRabbit::Client::PerformanceMonitor) }

    before do
      ActiveRabbit::Client.configure do |config|
        config.api_key = api_key
        config.project_id = project_id
      end

      allow(ActiveRabbit::Client::PerformanceMonitor).to receive(:new).and_return(performance_monitor)
    end

    it "calls the performance monitor when configured" do
      expect(performance_monitor).to receive(:track_performance).with(
        name: "test_operation",
        duration_ms: 1500.0,
        metadata: { key: "value" }
      )

      ActiveRabbit::Client.track_performance(
        "test_operation",
        1500.0,
        metadata: { key: "value" }
      )
    end

    it "does nothing when not configured" do
      ActiveRabbit::Client.configuration = nil

      expect(ActiveRabbit::Client::PerformanceMonitor).not_to receive(:new)

      ActiveRabbit::Client.track_performance("test_operation", 1500.0)
    end
  end

  describe ".flush" do
    let(:event_processor) { instance_double(ActiveRabbit::Client::EventProcessor) }
    let(:exception_tracker) { instance_double(ActiveRabbit::Client::ExceptionTracker) }
    let(:performance_monitor) { instance_double(ActiveRabbit::Client::PerformanceMonitor) }

    before do
      ActiveRabbit::Client.configure do |config|
        config.api_key = api_key
        config.project_id = project_id
      end

      allow(ActiveRabbit::Client::EventProcessor).to receive(:new).and_return(event_processor)
      allow(ActiveRabbit::Client::ExceptionTracker).to receive(:new).and_return(exception_tracker)
      allow(ActiveRabbit::Client::PerformanceMonitor).to receive(:new).and_return(performance_monitor)
    end

    it "flushes all components when configured" do
      expect(event_processor).to receive(:flush)
      expect(exception_tracker).to receive(:flush)
      expect(performance_monitor).to receive(:flush)

      ActiveRabbit::Client.flush
    end

    it "does nothing when not configured" do
      ActiveRabbit::Client.configuration = nil

      expect(ActiveRabbit::Client::EventProcessor).not_to receive(:new)

      ActiveRabbit::Client.flush
    end
  end

    describe ".shutdown" do
    let(:event_processor) { instance_double(ActiveRabbit::Client::EventProcessor) }
    let(:exception_tracker) { instance_double(ActiveRabbit::Client::ExceptionTracker) }
    let(:performance_monitor) { instance_double(ActiveRabbit::Client::PerformanceMonitor) }
    let(:http_client) { instance_double(ActiveRabbit::Client::HttpClient) }

    before do
      ActiveRabbit::Client.configure do |config|
        config.api_key = api_key
        config.project_id = project_id
      end

      allow(ActiveRabbit::Client::EventProcessor).to receive(:new).and_return(event_processor)
      allow(ActiveRabbit::Client::ExceptionTracker).to receive(:new).and_return(exception_tracker)
      allow(ActiveRabbit::Client::PerformanceMonitor).to receive(:new).and_return(performance_monitor)
      allow(ActiveRabbit::Client::HttpClient).to receive(:new).and_return(http_client)
    end

    it "shuts down all components when configured" do
      # First call flush
      expect(event_processor).to receive(:flush)
      expect(exception_tracker).to receive(:flush)
      expect(performance_monitor).to receive(:flush)

      # Then shutdown components
      expect(event_processor).to receive(:shutdown)
      expect(http_client).to receive(:shutdown)

      ActiveRabbit::Client.shutdown
    end

    it "does nothing when not configured" do
      ActiveRabbit::Client.configuration = nil

      expect(ActiveRabbit::Client::EventProcessor).not_to receive(:new)

      ActiveRabbit::Client.shutdown
    end
  end
end
