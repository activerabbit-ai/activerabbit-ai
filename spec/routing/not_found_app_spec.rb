# frozen_string_literal: true

require "spec_helper"
require "rack/mock"
module ActionController; class RoutingError < StandardError; end; end unless defined?(ActionController::RoutingError)
require_relative "../../lib/active_rabbit/routing/not_found_app"
require_relative "../../lib/active_rabbit/reporting"

RSpec.describe ActiveRabbit::Routing::NotFoundApp do
  let(:app) { described_class.new }

  before do
    ActiveRabbit::Client.configure do |config|
      config.api_key = "key"
      config.project_id = "p"
      config.api_url = "https://api.example.com"
    end
  end

  it "reports 404 via Reporting and returns 404 response" do
    env = Rack::MockRequest.env_for("/missing", method: "GET")

    expect(ActiveRabbit::Reporting).to receive(:report_exception)
      .with(instance_of(ActionController::RoutingError), env: env, handled: true, source: "router", force: true)

    status, headers, body = app.call(env)

    expect(status).to eq(404)
    expect(headers["Content-Type"]).to eq("text/plain")
    expect(body.join).to include("Not Found")
  end
end


