# frozen_string_literal: true

# Example Rails integration for ActiveRabbit::Client

# config/initializers/active_rabbit.rb
ActiveRabbit::Client.configure do |config|
  # Required configuration
  config.api_key = ENV['ACTIVERABBIT_API_KEY']
  config.project_id = ENV['ACTIVERABBIT_PROJECT_ID']
  config.environment = Rails.env

  # Optional configuration
  config.api_url = ENV.fetch('ACTIVERABBIT_API_URL', 'https://api.activerabbit.com')
  config.release = ENV['HEROKU_SLUG_COMMIT'] || `git rev-parse HEAD`.chomp

  # Performance settings
  config.enable_performance_monitoring = Rails.env.production?
  config.enable_n_plus_one_detection = true
  config.batch_size = 50
  config.flush_interval = 15

  # PII protection
  config.enable_pii_scrubbing = true
  config.pii_fields += %w[
    customer_id
    internal_notes
    admin_comments
  ]

  # Exception filtering
  config.ignored_exceptions += %w[
    MyApp::BusinessLogicError
    MyApp::ExpectedError
  ]

  # User agent filtering (ignore bots in production)
  if Rails.env.production?
    config.ignored_user_agents += [
      /HeadlessChrome/i,
      /PhantomJS/i,
      /SiteAudit/i
    ]
  end

  # Callbacks for additional processing
  config.before_send_exception = proc do |exception_data|
    # Add deployment information
    exception_data[:deployment] = {
      version: ENV['APP_VERSION'],
      build_number: ENV['BUILD_NUMBER']
    }

    # Don't send exceptions in test environment
    return nil if Rails.env.test?

    exception_data
  end

  config.before_send_event = proc do |event_data|
    # Add user context if available
    if current_user = Thread.current[:current_user]
      event_data[:user_context] = {
        id: current_user.id,
        plan: current_user.plan,
        created_at: current_user.created_at
      }
    end

    event_data
  end
end

# app/controllers/application_controller.rb
class ApplicationController < ActionController::Base
  before_action :set_active_rabbit_context

  private

  def set_active_rabbit_context
    # Set current user for ActiveRabbit context
    Thread.current[:current_user] = current_user

    # Add additional request context
    if Thread.current[:active_rabbit_request_context]
      Thread.current[:active_rabbit_request_context].merge!(
        user_id: current_user&.id,
        user_plan: current_user&.plan,
        tenant_id: current_tenant&.id
      )
    end
  end
end

# app/controllers/orders_controller.rb
class OrdersController < ApplicationController
  def create
    # Manual exception tracking with context
    begin
      @order = Order.create!(order_params)

      # Track successful order creation
      ActiveRabbit::Client.track_event(
        'order_created',
        {
          order_id: @order.id,
          amount: @order.total_amount,
          items_count: @order.items.count,
          payment_method: @order.payment_method
        },
        user_id: current_user.id
      )

      redirect_to @order, notice: 'Order was successfully created.'
    rescue PaymentProcessor::Error => e
      # Track payment errors with additional context
      ActiveRabbit::Client.track_exception(
        e,
        context: {
          order_params: order_params.to_h,
          payment_method: params[:payment_method],
          user_id: current_user.id
        },
        tags: {
          component: 'payment_processor',
          severity: 'high'
        }
      )

      redirect_to new_order_path, alert: 'Payment failed. Please try again.'
    end
  end

  def show
    # Performance monitoring for complex operations
    @order = ActiveRabbit::Client.performance_monitor.measure('order_loading') do
      Order.includes(:items, :customer, :shipping_address).find(params[:id])
    end
  end

  private

  def order_params
    params.require(:order).permit(:customer_id, items_attributes: [:product_id, :quantity])
  end
end

# app/jobs/order_processing_job.rb
class OrderProcessingJob < ApplicationJob
  def perform(order_id)
    order = Order.find(order_id)

    # Sidekiq integration will automatically track this job
    # But you can add custom events for important milestones

    ActiveRabbit::Client.track_event(
      'order_processing_started',
      { order_id: order.id },
      user_id: order.customer_id
    )

    # Process the order
    process_inventory(order)
    charge_payment(order)
    send_confirmation_email(order)

    ActiveRabbit::Client.track_event(
      'order_processing_completed',
      {
        order_id: order.id,
        processing_time: Time.current - order.created_at
      },
      user_id: order.customer_id
    )
  end

  private

  def process_inventory(order)
    # Custom performance tracking
    ActiveRabbit::Client.track_performance(
      'inventory_processing',
      measure_time { update_inventory_levels(order) },
      metadata: {
        order_id: order.id,
        items_count: order.items.count
      }
    )
  end

  def measure_time
    start_time = Time.current
    yield
    ((Time.current - start_time) * 1000).round(2)
  end
end

# app/models/order.rb
class Order < ApplicationRecord
  has_many :items
  belongs_to :customer

  after_create :track_creation
  after_update :track_status_changes

  private

  def track_creation
    ActiveRabbit::Client.track_event(
      'model_order_created',
      {
        id: id,
        customer_id: customer_id,
        total_amount: total_amount
      }
    )
  end

  def track_status_changes
    if saved_change_to_status?
      ActiveRabbit::Client.track_event(
        'order_status_changed',
        {
          order_id: id,
          from_status: status_before_last_save,
          to_status: status,
          customer_id: customer_id
        }
      )
    end
  end
end

# config/environments/production.rb
Rails.application.configure do
  # ... other configuration ...

  # Ensure ActiveRabbit client shuts down gracefully
  config.after_initialize do
    at_exit do
      ActiveRabbit::Client.shutdown if ActiveRabbit::Client.configured?
    end
  end
end
