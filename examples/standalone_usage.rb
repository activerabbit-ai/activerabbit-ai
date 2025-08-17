# frozen_string_literal: true

# Example standalone usage of ActiveAgent::Client (non-Rails applications)

require 'active_agent/client'

# Basic configuration
ActiveAgent::Client.configure do |config|
  config.api_key = 'your-api-key-here'
  config.project_id = 'your-project-id'
  config.api_url = 'https://api.activeagent.com'
  config.environment = ENV.fetch('RACK_ENV', 'development')

  # Standalone applications might want different settings
  config.batch_size = 20
  config.flush_interval = 10
  config.enable_performance_monitoring = true
  config.enable_pii_scrubbing = true
end

# Example: Sinatra application
require 'sinatra'

class MyApp < Sinatra::Base
  configure do
    # Add exception handling middleware
    use Rack::CommonLogger

    # Custom middleware for ActiveAgent context
    use Class.new do
      def initialize(app)
        @app = app
      end

      def call(env)
        request = Rack::Request.new(env)

        # Set request context
        Thread.current[:active_agent_request_context] = {
          method: request.request_method,
          path: request.path_info,
          query_string: request.query_string,
          user_agent: request.user_agent,
          ip_address: request.ip
        }

        begin
          @app.call(env)
        rescue Exception => e
          # Track unhandled exceptions
          ActiveAgent::Client.track_exception(
            e,
            context: {
              request: {
                method: request.request_method,
                path: request.path_info,
                params: request.params
              }
            }
          )
          raise
        ensure
          Thread.current[:active_agent_request_context] = nil
        end
      end
    end
  end

  get '/api/users/:id' do
    # Track API endpoint usage
    ActiveAgent::Client.track_event(
      'api_endpoint_accessed',
      {
        endpoint: '/api/users/:id',
        user_id: params[:id]
      }
    )

    # Performance monitoring
    user_data = ActiveAgent::Client.performance_monitor.measure('user_lookup') do
      # Simulate database lookup
      sleep(0.1)
      { id: params[:id], name: "User #{params[:id]}" }
    end

    content_type :json
    user_data.to_json
  end

  post '/api/process' do
    begin
      # Process some data
      result = process_data(params)

      ActiveAgent::Client.track_event(
        'data_processed',
        {
          records_processed: result[:count],
          processing_time_ms: result[:duration]
        }
      )

      { status: 'success', result: result }.to_json
    rescue ProcessingError => e
      ActiveAgent::Client.track_exception(
        e,
        context: {
          input_data: params,
          processing_stage: e.stage
        },
        tags: {
          component: 'data_processor',
          severity: 'medium'
        }
      )

      status 422
      { error: 'Processing failed' }.to_json
    end
  end

  private

  def process_data(data)
    start_time = Time.current

    # Simulate processing
    count = data['items']&.length || 0
    sleep(count * 0.01) # Simulate work

    {
      count: count,
      duration: ((Time.current - start_time) * 1000).round(2)
    }
  end
end

# Example: Background worker script
class BackgroundWorker
  def initialize
    # Configure ActiveAgent for background processes
    ActiveAgent::Client.configure do |config|
      config.api_key = ENV['ACTIVE_AGENT_API_KEY']
      config.project_id = ENV['ACTIVE_AGENT_PROJECT_ID']
      config.environment = ENV.fetch('ENVIRONMENT', 'development')
      config.server_name = "worker-#{Socket.gethostname}"
    end
  end

  def run
    puts "Starting background worker..."

    ActiveAgent::Client.track_event('worker_started', {
      hostname: Socket.gethostname,
      pid: Process.pid
    })

    loop do
      begin
        job = fetch_next_job
        break unless job

        process_job(job)
      rescue => e
        ActiveAgent::Client.track_exception(
          e,
          context: { component: 'background_worker' },
          tags: { severity: 'high' }
        )

        sleep 5 # Wait before retrying
      end
    end

    ActiveAgent::Client.track_event('worker_stopped')
    ActiveAgent::Client.shutdown
  end

  private

  def fetch_next_job
    # Simulate job fetching
    return nil if rand > 0.8 # 20% chance of getting a job

    {
      id: SecureRandom.uuid,
      type: ['email', 'report', 'cleanup'].sample,
      data: { user_id: rand(1000) }
    }
  end

  def process_job(job)
    transaction_id = ActiveAgent::Client.performance_monitor.start_transaction(
      "job_#{job[:type]}",
      metadata: { job_id: job[:id] }
    )

    begin
      # Simulate job processing
      case job[:type]
      when 'email'
        send_email(job[:data])
      when 'report'
        generate_report(job[:data])
      when 'cleanup'
        cleanup_data(job[:data])
      end

      ActiveAgent::Client.track_event(
        'job_completed',
        {
          job_id: job[:id],
          job_type: job[:type]
        }
      )
    rescue => e
      ActiveAgent::Client.track_exception(
        e,
        context: {
          job: job,
          component: 'job_processor'
        }
      )
      raise
    ensure
      ActiveAgent::Client.performance_monitor.finish_transaction(
        transaction_id,
        additional_metadata: { status: 'completed' }
      )
    end
  end

  def send_email(data)
    sleep(0.2) # Simulate email sending
  end

  def generate_report(data)
    sleep(0.5) # Simulate report generation
  end

  def cleanup_data(data)
    sleep(0.1) # Simulate cleanup
  end
end

# Example: Rake task integration
# lib/tasks/data_migration.rake
namespace :data do
  desc "Migrate user data"
  task migrate_users: :environment do
    ActiveAgent::Client.configure do |config|
      config.api_key = ENV['ACTIVE_AGENT_API_KEY']
      config.project_id = ENV['ACTIVE_AGENT_PROJECT_ID']
      config.environment = 'migration'
    end

    start_time = Time.current
    processed_count = 0
    error_count = 0

    ActiveAgent::Client.track_event('migration_started', {
      task: 'migrate_users',
      started_at: start_time
    })

    begin
      User.find_each do |user|
        begin
          migrate_user(user)
          processed_count += 1
        rescue => e
          error_count += 1
          ActiveAgent::Client.track_exception(
            e,
            context: {
              user_id: user.id,
              migration_task: 'migrate_users'
            }
          )
        end
      end

      duration = Time.current - start_time

      ActiveAgent::Client.track_event('migration_completed', {
        task: 'migrate_users',
        duration_seconds: duration.round(2),
        processed_count: processed_count,
        error_count: error_count
      })

      puts "Migration completed: #{processed_count} users processed, #{error_count} errors"
    ensure
      ActiveAgent::Client.shutdown
    end
  end
end

# Usage examples:

# 1. Run the Sinatra app
# ruby standalone_usage.rb

# 2. Run the background worker
# worker = BackgroundWorker.new
# worker.run

# 3. Run the rake task
# rake data:migrate_users
