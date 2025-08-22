# frozen_string_literal: true

# Example Rails Application Testing with ActiveRabbit
# This file shows how to test ActiveRabbit integration in your Rails app

# spec/support/active_rabbit_helpers.rb
module ActiveRabbitHelpers
  def setup_active_rabbit_test
    ActiveRabbit::Client.configure do |config|
      config.api_key = "test-api-key"
      config.project_id = "test-project"
      config.api_url = "https://api.activerabbit.com"
      config.environment = "test"
    end

    # Stub all API calls
    stub_active_rabbit_api
  end

  def stub_active_rabbit_api
    stub_request(:post, "https://api.activerabbit.com/api/v1/exceptions")
      .to_return(status: 200, body: '{"status":"ok"}')

    stub_request(:post, "https://api.activerabbit.com/api/v1/events")
      .to_return(status: 200, body: '{"status":"ok"}')

    stub_request(:post, "https://api.activerabbit.com/api/v1/performance")
      .to_return(status: 200, body: '{"status":"ok"}')

    stub_request(:post, "https://api.activerabbit.com/api/v1/batch")
      .to_return(status: 200, body: '{"status":"ok"}')
  end

  def expect_exception_tracked(exception_type: nil, message: nil, context: nil)
    expect(WebMock).to have_requested(:post, "https://api.activerabbit.com/api/v1/exceptions")
      .with { |request|
        body = JSON.parse(request.body)

        result = true
        result &&= body["type"] == exception_type if exception_type
        result &&= body["message"].include?(message) if message

        if context
          context.each do |key, value|
            result &&= body.dig("context", key.to_s) == value
          end
        end

        result
      }
  end

  def expect_event_tracked(event_name, properties: nil)
    expect(WebMock).to have_requested(:post, "https://api.activerabbit.com/api/v1/events")
      .with { |request|
        body = JSON.parse(request.body)

        result = body["name"] == event_name

        if properties
          properties.each do |key, value|
            result &&= body.dig("properties", key.to_s) == value
          end
        end

        result
      }
  end

  def expect_performance_tracked(operation_name, min_duration: nil)
    expect(WebMock).to have_requested(:post, "https://api.activerabbit.com/api/v1/performance")
      .with { |request|
        body = JSON.parse(request.body)

        result = body["name"] == operation_name
        result &&= body["duration_ms"] >= min_duration if min_duration

        result
      }
  end
end

# Include in RSpec configuration
# spec/rails_helper.rb
RSpec.configure do |config|
  config.include ActiveRabbitHelpers

  config.before(:each) do
    setup_active_rabbit_test
  end

  config.after(:each) do
    ActiveRabbit::Client.configuration = nil
    Thread.current[:active_rabbit_request_context] = nil
  end
end

# Example controller test
# spec/controllers/users_controller_spec.rb
RSpec.describe UsersController, type: :controller do
  describe "GET #show" do
    context "when user exists" do
      let(:user) { create(:user) }

      it "returns the user successfully" do
        get :show, params: { id: user.id }

        expect(response).to have_http_status(:success)

        # Should track performance but no exceptions
        expect_performance_tracked("controller.action")
        expect(WebMock).not_to have_requested(:post, /exceptions/)
      end
    end

    context "when user does not exist" do
      it "tracks the RecordNotFound exception" do
        expect {
          get :show, params: { id: 999999 }
        }.to raise_error(ActiveRecord::RecordNotFound)

        expect_exception_tracked(
          exception_type: "ActiveRecord::RecordNotFound",
          message: "Couldn't find User",
          context: {
            "request" => hash_including(
              "method" => "GET",
              "path" => "/users/999999"
            )
          }
        )
      end
    end
  end

  describe "POST #create" do
    context "with valid parameters" do
      let(:valid_params) { { user: { name: "John Doe", email: "john@example.com" } } }

      it "creates user and tracks success event" do
        expect {
          post :create, params: valid_params
        }.to change(User, :count).by(1)

        expect_event_tracked(
          "user_created",
          properties: {
            "source" => "web"
          }
        )
      end
    end

    context "with invalid parameters" do
      let(:invalid_params) { { user: { name: "" } } }

      it "tracks validation failure" do
        post :create, params: invalid_params

        expect_event_tracked(
          "user_creation_failed",
          properties: {
            "errors" => array_including("Name can't be blank")
          }
        )
      end
    end
  end
end

# Example model test
# spec/models/user_spec.rb
RSpec.describe User, type: :model do
  describe "callbacks" do
    it "tracks user creation event" do
      user = create(:user)

      expect_event_tracked(
        "model_user_created",
        properties: {
          "id" => user.id
        }
      )
    end

    it "tracks user status changes" do
      user = create(:user, status: "pending")
      user.update(status: "active")

      expect_event_tracked(
        "user_status_changed",
        properties: {
          "from_status" => "pending",
          "to_status" => "active"
        }
      )
    end
  end

  describe "error handling" do
    it "tracks validation errors" do
      user = build(:user, email: "invalid-email")

      expect(user.valid?).to be false

      # If you've added custom tracking for validation errors
      expect_event_tracked(
        "validation_failed",
        properties: {
          "model" => "User",
          "errors" => ["Email is invalid"]
        }
      )
    end
  end
end

# Example job test
# spec/jobs/user_notification_job_spec.rb
RSpec.describe UserNotificationJob, type: :job do
  let(:user) { create(:user) }

  describe "#perform" do
    context "when job succeeds" do
      it "tracks job completion" do
        perform_enqueued_jobs do
          UserNotificationJob.perform_later(user.id)
        end

        expect_event_tracked("sidekiq_job_completed")
        expect_performance_tracked("sidekiq.job")
      end
    end

    context "when job fails" do
      before do
        allow_any_instance_of(UserNotificationJob).to receive(:perform)
          .and_raise(StandardError, "Email service unavailable")
      end

      it "tracks job failure and exception" do
        expect {
          perform_enqueued_jobs do
            UserNotificationJob.perform_later(user.id)
          end
        }.to raise_error(StandardError, "Email service unavailable")

        expect_exception_tracked(
          exception_type: "StandardError",
          message: "Email service unavailable"
        )

        expect_event_tracked("sidekiq_job_failed")
      end
    end
  end
end

# Example feature test
# spec/features/user_registration_spec.rb
RSpec.describe "User Registration", type: :feature do
  scenario "successful user registration" do
    visit new_user_registration_path

    fill_in "Name", with: "John Doe"
    fill_in "Email", with: "john@example.com"
    fill_in "Password", with: "password123"

    click_button "Sign Up"

    expect(page).to have_content("Welcome, John!")

    # Verify tracking
    expect_event_tracked(
      "user_signup",
      properties: {
        "source" => "website"
      }
    )
  end

  scenario "user registration with invalid data" do
    visit new_user_registration_path

    fill_in "Email", with: "invalid-email"
    click_button "Sign Up"

    expect(page).to have_content("Email is invalid")

    # Should track the validation failure
    expect_event_tracked("user_signup_failed")
  end

  scenario "handles server errors gracefully" do
    # Simulate a server error during registration
    allow_any_instance_of(UsersController).to receive(:create)
      .and_raise(StandardError, "Database connection failed")

    visit new_user_registration_path

    fill_in "Name", with: "John Doe"
    fill_in "Email", with: "john@example.com"

    expect {
      click_button "Sign Up"
    }.to raise_error(StandardError)

    # Verify exception was tracked
    expect_exception_tracked(
      exception_type: "StandardError",
      message: "Database connection failed"
    )
  end
end

# Example request test for API endpoints
# spec/requests/api/users_spec.rb
RSpec.describe "API::Users", type: :request do
  describe "GET /api/users/:id" do
    let(:user) { create(:user) }

    context "with valid request" do
      it "returns user data and tracks API usage" do
        get "/api/users/#{user.id}", headers: {
          "Accept" => "application/json",
          "User-Agent" => "MyApp/1.0"
        }

        expect(response).to have_http_status(:success)

        expect_event_tracked(
          "api_endpoint_accessed",
          properties: {
            "endpoint" => "/api/users/:id",
            "method" => "GET"
          }
        )
      end
    end

    context "with invalid user ID" do
      it "returns 404 and tracks the error" do
        get "/api/users/999999", headers: { "Accept" => "application/json" }

        expect(response).to have_http_status(:not_found)

        expect_exception_tracked(
          exception_type: "ActiveRecord::RecordNotFound"
        )
      end
    end
  end

  describe "POST /api/users" do
    context "with rate limiting" do
      it "tracks rate limit violations" do
        # Simulate rate limiting
        allow_any_instance_of(ApplicationController).to receive(:check_rate_limit)
          .and_raise(RateLimitExceeded, "Too many requests")

        expect {
          post "/api/users", params: { user: { name: "Test" } }
        }.to raise_error(RateLimitExceeded)

        expect_exception_tracked(
          exception_type: "RateLimitExceeded",
          message: "Too many requests"
        )
      end
    end
  end
end

# Example system test
# spec/system/error_handling_spec.rb
RSpec.describe "Error Handling", type: :system do
  before do
    driven_by(:selenium_chrome_headless)
  end

  scenario "handles JavaScript errors" do
    # If you have JavaScript error tracking
    visit some_page_with_js_error

    # Trigger JS error
    click_button "Trigger Error"

    # Verify JS error was tracked (if implemented)
    expect_event_tracked("javascript_error")
  end

  scenario "handles network timeouts" do
    # Simulate slow external API
    stub_request(:get, "https://external-api.com/data")
      .to_timeout

    visit page_that_calls_external_api

    # Should handle gracefully and track the timeout
    expect_exception_tracked(
      exception_type: "Net::TimeoutError"
    )
  end
end

# Performance test example
# spec/performance/activerabbit_impact_spec.rb
RSpec.describe "ActiveRabbit Performance Impact" do
  let(:iterations) { 100 }

  it "has minimal impact on controller actions" do
    # Baseline without ActiveRabbit
    ActiveRabbit::Client.configuration = nil

    baseline_time = Benchmark.measure do
      iterations.times do
        get "/users/1"
      end
    end

    # With ActiveRabbit enabled
    setup_active_rabbit_test

    activerabbit_time = Benchmark.measure do
      iterations.times do
        get "/users/1"
      end
    end

    # Calculate overhead
    overhead_percent = ((activerabbit_time.real - baseline_time.real) / baseline_time.real) * 100

    expect(overhead_percent).to be < 5,
      "ActiveRabbit overhead (#{overhead_percent.round(2)}%) exceeds 5% threshold"
  end
end

