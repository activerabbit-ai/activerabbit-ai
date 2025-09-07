# frozen_string_literal: true

require "spec_helper"
require_relative "../../lib/active_rabbit/reporting"

RSpec.describe ActiveRabbit::Reporting do
  describe ".report_exception" do
    before do
      ActiveRabbit::Client.configure do |config|
        config.api_key = "k"
        config.project_id = "p"
        config.api_url = "https://api.example.com"
      end
    end

    it "uses Client.track_exception with enriched context" do
      error = RuntimeError.new("oops")
      env = { "REQUEST_METHOD" => "GET", "PATH_INFO" => "/x" }

      expect(ActiveRabbit::Client).to receive(:track_exception).with(
        error,
        context: hash_including(:request, :routing, source: "rails", handled: false),
        handled: false,
        force: false
      )

      described_class.report_exception(error, env: env)
    end
  end
end


