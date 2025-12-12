# frozen_string_literal: true

require "spec_helper"
require "webmock/rspec"

if !defined?(Rails)
  RSpec.describe "Rails Error Taxonomy Integration" do
    it "skips because Rails is not available in this test environment" do
      skip "Rails not available"
    end
  end
else
RSpec.describe "Rails Error Taxonomy Integration", type: :request do
  before do
    ActiveRabbit::Client.configure do |config|
      config.api_key = "test-api-key"
      config.project_id = "test-project"
      config.api_url = "https://api.activerabbit.com"
      config.enable_404 = false
    end

    stub_request(:post, %r{https://api\.activerabbit\.com/api/v1/(exceptions|events|batch|performance)})
      .to_return(status: 200, body: '{"status":"ok"}')
  end

  after do
    Rails.application.reload_routes!
  end

  def expect_report_sent
    expect(WebMock).to have_requested(:post, %r{https://api\.activerabbit\.com/api/v1/(exceptions|events)})
  end

  describe "Routing / method / format" do
    it "reports ActionController::RoutingError via exceptions_app" do
      begin
        Rails.application.config.exceptions_app = ActiveRabbit::Routing::NotFoundApp.new
      rescue NameError
        skip "NotFoundApp not available"
      end

      get "/definitely_missing_#{SecureRandom.hex(4)}"
      expect(response.status).to eq(404)
      expect_report_sent
    end

    it "reports ActionController::UnknownFormat" do
      Rails.application.routes.draw do
        get "/unknown_format_demo", to: proc { |_env| raise ActionController::UnknownFormat }
      end

      expect { get "/unknown_format_demo.json" }.to raise_error(ActionController::UnknownFormat)
      expect_report_sent
    end

    it "reports ActionController::UnknownHttpMethod" do
      Rails.application.routes.draw do
        get "/unknown_method_demo", to: proc { |_env| raise ActionController::UnknownHttpMethod.new("BREW") }
      end

      expect { get "/unknown_method_demo" }.to raise_error(ActionController::UnknownHttpMethod)
      expect_report_sent
    end
  end

  describe "Bad/unsafe requests" do
    it "reports ActionController::BadRequest" do
      Rails.application.routes.draw do
        get "/bad_request_demo", to: proc { |_env| raise ActionController::BadRequest, "bad" }
      end

      expect { get "/bad_request_demo" }.to raise_error(ActionController::BadRequest)
      expect_report_sent
    end

    it "reports ActionController::ParameterMissing" do
      Rails.application.routes.draw do
        get "/param_missing_demo", to: proc { |_env| raise ActionController::ParameterMissing.new(:needed) }
      end

      expect { get "/param_missing_demo" }.to raise_error(ActionController::ParameterMissing)
      expect_report_sent
    end

    it "reports ActionDispatch::Http::Parameters::ParseError" do
      Rails.application.routes.draw do
        post "/parse_error_demo", to: proc { |_env| raise ActionDispatch::Http::Parameters::ParseError.new("malformed") }
      end

      expect { post "/parse_error_demo", params: '{bad:}', headers: { 'Content-Type' => 'application/json' } }
        .to raise_error(ActionDispatch::Http::Parameters::ParseError)
      expect_report_sent
    end

    it "reports ActionController::InvalidAuthenticityToken" do
      Rails.application.routes.draw do
        post "/csrf_demo", to: proc { |_env| raise ActionController::InvalidAuthenticityToken }
      end

      expect { post "/csrf_demo" }.to raise_error(ActionController::InvalidAuthenticityToken)
      expect_report_sent
    end
  end

  describe "Resource not found" do
    it "reports ActiveRecord::RecordNotFound" do
      Rails.application.routes.draw do
        get "/record_not_found_demo", to: proc { |_env| raise ActiveRecord::RecordNotFound, "missing" }
      end

      expect { get "/record_not_found_demo" }.to raise_error(ActiveRecord::RecordNotFound)
      expect_report_sent
    end
  end

  describe "View/template" do
    it "reports ActionView::MissingTemplate" do
      Rails.application.routes.draw do
        get "/missing_template_demo", to: proc { |_env| raise ActionView::MissingTemplate.new([], "path", [], false, {}) }
      end

      expect { get "/missing_template_demo" }.to raise_error(ActionView::MissingTemplate)
      expect_report_sent
    end

    it "reports ActionView::Template::Error" do
      Rails.application.routes.draw do
        get "/template_error_demo", to: proc { |_env|
          begin
            raise "boom"
          rescue => e
            raise ActionView::Template::Error.new(e, nil)
          end
        }
      end

      expect { get "/template_error_demo" }.to raise_error(ActionView::Template::Error)
      expect_report_sent
    end
  end
end
end


