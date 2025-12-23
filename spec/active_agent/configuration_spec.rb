# frozen_string_literal: true

RSpec.describe ActiveRabbit::Client::Configuration do
  let(:config) { described_class.new }

  describe "#initialize" do
    it "sets default values" do
      expect(config.api_url).to eq("https://app.activerabbit.ai")
      expect(config.timeout).to eq(30)
      expect(config.open_timeout).to eq(10)
      expect(config.retry_count).to eq(3)
      expect(config.retry_delay).to eq(1)
      expect(config.batch_size).to eq(100)
      expect(config.flush_interval).to eq(30)
      expect(config.queue_size).to eq(1000)
      expect(config.enable_performance_monitoring).to be true
      expect(config.enable_n_plus_one_detection).to be true
      expect(config.enable_pii_scrubbing).to be true
    end

    it "loads values from environment variables" do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("ACTIVERABBIT_API_KEY").and_return("env-api-key")
      allow(ENV).to receive(:[]).with("ACTIVERABBIT_PROJECT_ID").and_return("env-project-id")
      allow(ENV).to receive(:[]).with("ACTIVERABBIT_ENVIRONMENT").and_return("env-environment")
      allow(ENV).to receive(:fetch).and_call_original
      allow(ENV).to receive(:fetch).with("ACTIVERABBIT_API_URL", "https://app.activerabbit.ai").and_return("https://custom-api.com")

      config = described_class.new

      expect(config.api_key).to eq("env-api-key")
      expect(config.project_id).to eq("env-project-id")
      expect(config.environment).to eq("env-environment")
      expect(config.api_url).to eq("https://custom-api.com")
    end

    it "sets default PII fields" do
      expect(config.pii_fields).to include("password", "email", "ssn", "credit_card")
    end

    it "sets default ignored exceptions" do
      expect(config.ignored_exceptions).to include("ActiveRecord::RecordNotFound")
    end

    it "sets default ignored user agents" do
      expect(config.ignored_user_agents).to include(/Googlebot/i)
    end
  end

  describe "#valid?" do
    context "when api_key and api_url are present" do
      before do
        config.api_key = "test-key"
        config.api_url = "https://api.test.com"
      end

      it "returns true" do
        expect(config.valid?).to be true
      end
    end

    context "when api_key is missing" do
      before do
        config.api_key = nil
        config.api_url = "https://api.test.com"
      end

      it "returns false" do
        expect(config.valid?).to be false
      end
    end

    context "when api_url is missing" do
      before do
        config.api_key = "test-key"
        config.api_url = nil
      end

      it "returns false" do
        expect(config.valid?).to be false
      end
    end
  end

  describe "#api_endpoint" do
    before do
      config.api_url = "https://api.test.com"
    end

    it "builds endpoint URLs correctly" do
      expect(config.api_endpoint("events")).to eq("https://api.test.com/events")
      expect(config.api_endpoint("/events")).to eq("https://api.test.com/events")
    end

    it "handles trailing slashes in api_url" do
      config.api_url = "https://api.test.com/"
      expect(config.api_endpoint("events")).to eq("https://api.test.com/events")
    end
  end

  describe "#should_ignore_exception?" do
    let(:exception) { StandardError.new("test error") }

    context "when exception class name matches ignored list" do
      before do
        config.ignored_exceptions = ["StandardError"]
      end

      it "returns true" do
        expect(config.should_ignore_exception?(exception)).to be true
      end
    end

    context "when exception class matches ignored list" do
      before do
        config.ignored_exceptions = [StandardError]
      end

      it "returns true" do
        expect(config.should_ignore_exception?(exception)).to be true
      end
    end

    context "when exception class name matches regex in ignored list" do
      before do
        config.ignored_exceptions = [/Standard/]
      end

      it "returns true" do
        expect(config.should_ignore_exception?(exception)).to be true
      end
    end

    context "when exception is not in ignored list" do
      before do
        config.ignored_exceptions = ["RuntimeError"]
      end

      it "returns false" do
        expect(config.should_ignore_exception?(exception)).to be false
      end
    end

    context "when exception is nil" do
      it "returns false" do
        expect(config.should_ignore_exception?(nil)).to be false
      end
    end
  end

  describe "#should_ignore_user_agent?" do
    context "when user agent matches string in ignored list" do
      before do
        config.ignored_user_agents = ["Googlebot"]
      end

      it "returns true" do
        expect(config.should_ignore_user_agent?("Googlebot/2.1")).to be true
      end
    end

    context "when user agent matches regex in ignored list" do
      before do
        config.ignored_user_agents = [/Googlebot/i]
      end

      it "returns true" do
        expect(config.should_ignore_user_agent?("googlebot/2.1")).to be true
      end
    end

    context "when user agent is not in ignored list" do
      before do
        config.ignored_user_agents = [/Googlebot/i]
      end

      it "returns false" do
        expect(config.should_ignore_user_agent?("Mozilla/5.0")).to be false
      end
    end

    context "when user agent is nil" do
      it "returns false" do
        expect(config.should_ignore_user_agent?(nil)).to be false
      end
    end
  end
end
