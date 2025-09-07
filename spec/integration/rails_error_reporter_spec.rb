# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Rails Error Reporter Integration" do
  before do
    ActiveRabbit::Client.configure do |config|
      config.api_key = "k"
      config.project_id = "p"
      config.api_url = "https://api.example.com"
    end
  end

  it "subscribes and reports handled errors when Rails.error is available" do
    skip "Rails.error not available" unless defined?(Rails) && Rails.respond_to?(:error)

    subscriber = nil
    allow(Rails.error).to receive(:subscribe) do |&block|
      subscriber = block
    end

    # Reload attach!
    ActiveRabbit::Client::ErrorReporter.attach!

    expect(ActiveRabbit::Client).to receive(:track_exception)
      .with(instance_of(StandardError), hash_including(:handled), hash_including(:handled))
      .at_least(:once)

    # Simulate a handled event
    ex = StandardError.new("boom")
    subscriber.call(:handle, true, ex, { foo: :bar }) if subscriber
  end
end


