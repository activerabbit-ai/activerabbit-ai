# ActiveRabbit AI Client

Ruby client library for ActiveRabbit.ai application monitoring and error tracking. This gem provides comprehensive monitoring capabilities including error tracking, performance monitoring, N+1 query detection, and more for Ruby applications, with special focus on Rails integration.

## Features

- **Error Tracking**: Automatic exception capture with detailed context and stack traces
- **Performance Monitoring**: Track application performance metrics and slow operations
- **N+1 Query Detection**: Automatically detect and report N+1 database query issues
- **PII Scrubbing**: Built-in personally identifiable information filtering
- **Rails Integration**: Seamless Rails integration with automatic middleware setup
- **Sidekiq Integration**: Background job monitoring and error tracking
- **Batched Requests**: Efficient API communication with request batching
- **Configurable**: Extensive configuration options for different environments

## Installation

Add this line to your application's Gemfile:

```ruby
gem 'activerabbit-ai'
```

And then execute:

    $ bundle install

Or install it yourself as:

    $ gem install activerabbit-ai

## Quick Start

### Basic Configuration

```ruby
# config/initializers/activerabbit.rb
ActiveRabbit::Client.configure do |config|
  config.api_key = ENV['ACTIVERABBIT_API_KEY']
  config.project_id = ENV['ACTIVERABBIT_PROJECT_ID']
  config.api_url = ENV.fetch('ACTIVERABBIT_API_URL', 'https://api.activerabbit.ai')
  config.environment = Rails.env
end
```

### Environment Variables

You can also configure the client using environment variables:

```bash
export ACTIVERABBIT_API_KEY="your-api-key"
export ACTIVERABBIT_PROJECT_ID="your-project-id"
export ACTIVERABBIT_API_URL="https://app.activerabbit.ai"
export ACTIVERABBIT_ENVIRONMENT="production"
```

## Usage

### Manual Error Tracking

```ruby
begin
  # Some risky operation
  risky_operation
rescue => exception
  ActiveRabbit::Client.track_exception(
    exception,
    context: { user_id: current_user.id, action: 'risky_operation' },
    tags: { component: 'payment_processor' }
  )
  raise # Re-raise if needed
end
```

### Event Tracking

```ruby
# Track custom events
ActiveRabbit::Client.track_event(
  'user_signup',
  {
    plan: 'premium',
    source: 'website'
  },
  user_id: user.id
)
```

### Performance Monitoring

```ruby
# Manual performance tracking
ActiveRabbit::Client.track_performance(
  'database_migration',
  duration_ms: 1500,
  metadata: {
    migration: '20231201_add_indexes',
    records_affected: 10000
  }
)

# Block-based measurement
result = ActiveRabbit::Client.performance_monitor.measure('complex_calculation') do
  perform_complex_calculation
end
```

### Transaction Tracking

```ruby
# Start a performance transaction
transaction_id = ActiveRabbit::Client.performance_monitor.start_transaction(
  'order_processing',
  metadata: { order_id: order.id }
)

# ... perform operations ...

# Finish the transaction
ActiveRabbit::Client.performance_monitor.finish_transaction(
  transaction_id,
  additional_metadata: { items_count: order.items.count }
)
```

## Rails Integration

The gem automatically integrates with Rails when detected:

### Automatic Features

- **Exception Tracking**: Unhandled exceptions are automatically captured
- **Performance Monitoring**: Controller actions, database queries, and view renders are monitored
- **N+1 Detection**: Database query patterns are analyzed for N+1 issues
- **Request Context**: HTTP request information is automatically included

### Manual Rails Usage

```ruby
class ApplicationController < ActionController::Base
  before_action :set_activerabbit_context

  private

  def set_activerabbit_context
    # Additional context can be added to all requests
    Thread.current[:activerabbit_request_context] ||= {}
    Thread.current[:activerabbit_request_context][:user_id] = current_user&.id
  end
end
```

## Sidekiq Integration

Sidekiq integration is automatic when Sidekiq is detected:

```ruby
# Jobs are automatically monitored
class ProcessOrderJob < ApplicationJob
  def perform(order_id)
    order = Order.find(order_id)
    # Any exceptions here will be automatically tracked
    # Performance metrics will be collected
    process_order(order)
  end
end
```

## Configuration Options

### Basic Configuration

```ruby
ActiveRabbit::Client.configure do |config|
  # Required settings
  config.api_key = 'your-api-key'
  config.project_id = 'your-project-id'
  config.api_url = 'https://api.activerabbit.com'
  config.environment = 'production'

  # HTTP settings
  config.timeout = 30
  config.open_timeout = 10
  config.retry_count = 3
  config.retry_delay = 1

  # Batching settings
  config.batch_size = 100
  config.flush_interval = 30
  config.queue_size = 1000
end
```

### Feature Toggles

```ruby
ActiveRabbit::Client.configure do |config|
  # Enable/disable features
  config.enable_performance_monitoring = true
  config.enable_n_plus_one_detection = true
  config.enable_pii_scrubbing = true
end
```

### PII Scrubbing Configuration

```ruby
ActiveRabbit::Client.configure do |config|
  config.enable_pii_scrubbing = true
  config.pii_fields = %w[
    password password_confirmation token secret key
    credit_card ssn social_security_number phone email
    first_name last_name name address city state zip
    custom_sensitive_field
  ]
end
```

### Exception Filtering

```ruby
ActiveRabbit::Client.configure do |config|
  # Ignore specific exceptions
  config.ignored_exceptions = %w[
    ActiveRecord::RecordNotFound
    ActionController::RoutingError
    CustomBusinessLogicError
  ]

  # Ignore requests from specific user agents
  config.ignored_user_agents = [
    /Googlebot/i,
    /bingbot/i,
    /Custom-Bot/i
  ]
end
```

### Callbacks

```ruby
ActiveRabbit::Client.configure do |config|
  # Filter events before sending
  config.before_send_event = proc do |event_data|
    # Return nil to skip sending the event
    # Return modified event_data to send modified version
    return nil if event_data[:name] == 'debug_event'
    event_data
  end

  # Filter exceptions before sending
  config.before_send_exception = proc do |exception_data|
    # Add custom context
    exception_data[:custom_context] = {
      deployment_id: ENV['DEPLOYMENT_ID']
    }
    exception_data
  end
end
```

## API Reference

### ActiveRabbit::Client

Main client interface:

- `configure { |config| ... }` - Configure the client
- `configured?` - Check if client is properly configured
- `track_event(name, properties, user_id:, timestamp:)` - Track custom events
- `track_exception(exception, context:, user_id:, tags:)` - Track exceptions
- `track_performance(name, duration_ms, metadata:)` - Track performance metrics
- `flush` - Flush pending events immediately
- `shutdown` - Gracefully shutdown the client

### Configuration Options

- `api_key` - Your ActiveRabbit API key
- `project_id` - Your ActiveRabbit project ID
- `api_url` - ActiveRabbit API endpoint URL
- `environment` - Application environment (production, staging, etc.)
- `timeout` - HTTP request timeout
- `batch_size` - Number of events to batch together
- `flush_interval` - How often to flush batched events (seconds)
- `enable_performance_monitoring` - Enable/disable performance tracking
- `enable_n_plus_one_detection` - Enable/disable N+1 query detection
- `enable_pii_scrubbing` - Enable/disable PII scrubbing
- `pii_fields` - Array of field names to scrub
- `ignored_exceptions` - Array of exception classes/names to ignore
- `ignored_user_agents` - Array of user agent patterns to ignore

## Development

After checking out the repo, run `bin/setup` to install dependencies. Then, run `rake spec` to run the tests. You can also run `bin/console` for an interactive prompt that will allow you to experiment.

To install this gem onto your local machine, run `bundle exec rake install`. To release a new version, update the version number in `version.rb`, and then run `bundle exec rake release`, which will create a git tag for the version, push git commits and the created tag, and push the `.gem` file to [rubygems.org](https://rubygems.org).

## Testing

```bash
# Run all tests
bundle exec rspec

# Run with coverage
COVERAGE=true bundle exec rspec

# Run specific test file
bundle exec rspec spec/active_rabbit/client_spec.rb
```

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/bugrabbit/active_rabbit-client.

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
