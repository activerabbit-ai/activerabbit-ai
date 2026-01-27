# frozen_string_literal: true

require "spec_helper"

# Mock ActionMailer classes for testing without requiring full Rails
module ActionMailer
  class Base; end

  class MessageDelivery
    attr_reader :mailer_class, :action, :args

    def initialize(mailer_class, action, *args)
      @mailer_class = mailer_class
      @action = action
      @args = args
      @message_accessed = false
    end

    def message
      @message_accessed = true
      @message ||= MockMessage.new
    end

    def message_accessed?
      @message_accessed
    end

    def deliver_now
      message # Access the message for delivery
      :delivered_now
    end

    def deliver_later(...)
      # Rails' actual deliver_later would raise if message was accessed
      if @message_accessed
        raise RuntimeError, "You've accessed the message before asking to deliver it later"
      end
      :delivered_later
    end
  end

  class MockMessage
    def message_id
      "test-message-id-123"
    end

    def subject
      "Test Subject"
    end

    def to
      ["user@example.com"]
    end
  end
end

# Mock mailer class
class TestMailer < ActionMailer::Base
  def self.name
    "TestMailer"
  end
end

# Now load the patch (after ActionMailer is defined)
require "active_rabbit/client/action_mailer_patch"

RSpec.describe ActiveRabbit::Client::ActionMailerPatch do
  let(:api_key) { "test-api-key" }
  let(:project_id) { "test-project-id" }
  let(:user) { double("User", class: User) }

  # Mock User class for args tracking
  class User; end

  before do
    # Reset configuration before each test
    ActiveRabbit::Client.configuration = nil
    ActiveRabbit::Client.instance_variable_set(:@event_processor, nil)
    ActiveRabbit::Client.instance_variable_set(:@exception_tracker, nil)
    ActiveRabbit::Client.instance_variable_set(:@performance_monitor, nil)
    ActiveRabbit::Client.instance_variable_set(:@http_client, nil)
  end

  after do
    ActiveRabbit::Client.configuration = nil
    ActiveRabbit::Client.instance_variable_set(:@event_processor, nil)
    ActiveRabbit::Client.instance_variable_set(:@exception_tracker, nil)
    ActiveRabbit::Client.instance_variable_set(:@performance_monitor, nil)
    ActiveRabbit::Client.instance_variable_set(:@http_client, nil)
  end

  describe "#deliver_later" do
    let(:message_delivery) { ActionMailer::MessageDelivery.new(TestMailer, :welcome, user) }

    context "when ActiveRabbit is configured" do
      let(:event_processor) { instance_double(ActiveRabbit::Client::EventProcessor) }

      before do
        ActiveRabbit::Client.configure do |config|
          config.api_key = api_key
          config.project_id = project_id
        end

        allow(ActiveRabbit::Client::EventProcessor).to receive(:new).and_return(event_processor)
      end

      it "does NOT access the message object" do
        allow(event_processor).to receive(:track_event)

        message_delivery.deliver_later

        expect(message_delivery.message_accessed?).to be false
      end

      it "tracks email_enqueued event with correct metadata" do
        expect(event_processor).to receive(:track_event).with(
          name: "email_enqueued",
          properties: {
            mailer_class: "TestMailer",
            action: :welcome,
            args: ["User"]
          },
          user_id: nil,
          timestamp: kind_of(Time)
        )

        message_delivery.deliver_later
      end

      it "returns the result from the original deliver_later" do
        allow(event_processor).to receive(:track_event)

        result = message_delivery.deliver_later

        expect(result).to eq(:delivered_later)
      end

      it "does not raise RuntimeError about accessing message" do
        allow(event_processor).to receive(:track_event)

        expect { message_delivery.deliver_later }.not_to raise_error
      end
    end

    context "when ActiveRabbit is not configured" do
      it "does not track any events" do
        expect(ActiveRabbit::Client::EventProcessor).not_to receive(:new)

        message_delivery.deliver_later
      end

      it "still calls the original deliver_later" do
        result = message_delivery.deliver_later

        expect(result).to eq(:delivered_later)
      end

      it "does NOT access the message object" do
        message_delivery.deliver_later

        expect(message_delivery.message_accessed?).to be false
      end
    end

    context "with multiple arguments" do
      let(:arg1) { double("Arg1", class: String) }
      let(:arg2) { double("Arg2", class: Integer) }
      let(:message_delivery) { ActionMailer::MessageDelivery.new(TestMailer, :notify, arg1, arg2) }
      let(:event_processor) { instance_double(ActiveRabbit::Client::EventProcessor) }

      before do
        ActiveRabbit::Client.configure do |config|
          config.api_key = api_key
          config.project_id = project_id
        end

        allow(ActiveRabbit::Client::EventProcessor).to receive(:new).and_return(event_processor)
      end

      it "tracks all argument types" do
        expect(event_processor).to receive(:track_event).with(
          name: "email_enqueued",
          properties: hash_including(
            args: ["String", "Integer"]
          ),
          user_id: nil,
          timestamp: kind_of(Time)
        )

        message_delivery.deliver_later
      end
    end

    context "with no arguments" do
      let(:message_delivery) { ActionMailer::MessageDelivery.new(TestMailer, :daily_digest) }
      let(:event_processor) { instance_double(ActiveRabbit::Client::EventProcessor) }

      before do
        ActiveRabbit::Client.configure do |config|
          config.api_key = api_key
          config.project_id = project_id
        end

        allow(ActiveRabbit::Client::EventProcessor).to receive(:new).and_return(event_processor)
      end

      it "tracks empty args array" do
        expect(event_processor).to receive(:track_event).with(
          name: "email_enqueued",
          properties: hash_including(
            args: []
          ),
          user_id: nil,
          timestamp: kind_of(Time)
        )

        message_delivery.deliver_later
      end
    end
  end

  describe "#deliver_now" do
    let(:message_delivery) { ActionMailer::MessageDelivery.new(TestMailer, :welcome, user) }

    context "when ActiveRabbit is configured" do
      let(:event_processor) { instance_double(ActiveRabbit::Client::EventProcessor) }

      before do
        ActiveRabbit::Client.configure do |config|
          config.api_key = api_key
          config.project_id = project_id
        end

        allow(ActiveRabbit::Client::EventProcessor).to receive(:new).and_return(event_processor)
      end

      it "tracks email_sent event with message details" do
        expect(event_processor).to receive(:track_event).with(
          name: "email_sent",
          properties: hash_including(
            mailer_class: "TestMailer",
            action: :welcome,
            message_id: "test-message-id-123",
            subject: "Test Subject",
            to: "user@example.com"
          ),
          user_id: nil,
          timestamp: kind_of(Time)
        )

        message_delivery.deliver_now
      end

      it "includes duration_ms in tracked event" do
        expect(event_processor).to receive(:track_event).with(
          name: "email_sent",
          properties: hash_including(
            duration_ms: kind_of(Float)
          ),
          user_id: nil,
          timestamp: kind_of(Time)
        )

        message_delivery.deliver_now
      end

      it "returns the result from the original deliver_now" do
        allow(event_processor).to receive(:track_event)

        result = message_delivery.deliver_now

        expect(result).to eq(:delivered_now)
      end

      it "CAN access the message object (unlike deliver_later)" do
        allow(event_processor).to receive(:track_event)

        message_delivery.deliver_now

        expect(message_delivery.message_accessed?).to be true
      end
    end

    context "when ActiveRabbit is not configured" do
      it "does not track any events" do
        expect(ActiveRabbit::Client::EventProcessor).not_to receive(:new)

        message_delivery.deliver_now
      end

      it "still calls the original deliver_now" do
        result = message_delivery.deliver_now

        expect(result).to eq(:delivered_now)
      end
    end

    context "when message methods raise errors" do
      let(:event_processor) { instance_double(ActiveRabbit::Client::EventProcessor) }

      before do
        ActiveRabbit::Client.configure do |config|
          config.api_key = api_key
          config.project_id = project_id
        end

        allow(ActiveRabbit::Client::EventProcessor).to receive(:new).and_return(event_processor)

        # Mock message to raise errors
        allow_any_instance_of(ActionMailer::MockMessage).to receive(:subject).and_raise(StandardError, "Subject error")
        allow_any_instance_of(ActionMailer::MockMessage).to receive(:to).and_raise(StandardError, "To error")
        allow_any_instance_of(ActionMailer::MockMessage).to receive(:message_id).and_raise(StandardError, "MessageID error")
      end

      it "gracefully handles errors with rescue nil" do
        expect(event_processor).to receive(:track_event).with(
          name: "email_sent",
          properties: hash_including(
            mailer_class: "TestMailer",
            action: :welcome,
            message_id: nil,
            subject: nil,
            to: nil
          ),
          user_id: nil,
          timestamp: kind_of(Time)
        )

        expect { message_delivery.deliver_now }.not_to raise_error
      end
    end
  end

  describe "patch application" do
    it "prepends the patch to ActionMailer::MessageDelivery" do
      expect(ActionMailer::MessageDelivery.ancestors).to include(ActiveRabbit::Client::ActionMailerPatch)
    end

    it "has the patch as the first ancestor module" do
      # The patch should be prepended, so it should come before the class itself in method resolution
      patch_index = ActionMailer::MessageDelivery.ancestors.index(ActiveRabbit::Client::ActionMailerPatch)
      class_index = ActionMailer::MessageDelivery.ancestors.index(ActionMailer::MessageDelivery)

      expect(patch_index).to be < class_index
    end
  end
end
