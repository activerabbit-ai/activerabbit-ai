# frozen_string_literal: true

require "spec_helper"
require "rack"
require_relative "../../lib/active_rabbit/middleware/error_capture_middleware"
require_relative "../../lib/active_rabbit/reporting"

RSpec.describe ActiveRabbit::Middleware::ErrorCaptureMiddleware do
  let(:app) { ->(_env) { raise StandardError, "boom" } }
  let(:middleware) { described_class.new(app) }

  before do
    ActiveRabbit::Client.configure do |config|
      config.api_key = "test-key"
      config.project_id = "test"
      config.api_url = "https://api.example.com"
    end
  end

  it "reports unhandled exceptions and re-raises" do
    expect(ActiveRabbit::Reporting).to receive(:report_exception)
      .with(instance_of(StandardError), env: kind_of(Hash), handled: false, source: "middleware", force: true)

    expect { middleware.call({}) }.to raise_error(StandardError, "boom")
  end
end


