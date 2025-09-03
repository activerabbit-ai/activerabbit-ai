# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.2.0] - 2025-01-03

### 🚨 Major Rails Integration Improvements

This release fixes critical Rails integration issues that prevented reliable exception tracking in production environments.

### Fixed
- **Rails Autoload**: Fixed missing Railtie autoload in main entry point (`lib/active_rabbit.rb`)
- **Exception Middleware**: Properly positioned before `ActionDispatch::ShowExceptions` to catch raw exceptions
- **Rescued Exceptions**: Fixed `process_action.action_controller` subscriber to catch Rails-rescued exceptions
- **Thread Cleanup**: Improved `Thread.current` cleanup in middleware with proper nested request handling
- **Time Dependencies**: Added missing `require "time"` for `iso8601` method across all modules

### Added
- **Shutdown Hooks**: Added `at_exit` and `SIGTERM` handlers for graceful shutdown and data flushing
- **Enhanced Context**: Added timing data, sanitized headers, and better request context
- **Error Isolation**: All tracking operations now fail gracefully without breaking the application
- **Rails 7+ Support**: Handles both `exception_object` (Rails 7+) and legacy `exception` formats
- **Production Resilience**: Never blocks web requests, background sending with automatic retries

### Improved
- **PII Scrubbing**: Enhanced parameter and header sanitization
- **Exception Fingerprinting**: Better grouping of similar exceptions
- **Middleware Safety**: Robust error handling prevents tracking failures from affecting requests
- **Test Coverage**: Added comprehensive Rails integration test suite

### Technical Details
- Rack middleware now placed **before** Rails exception handling (critical for production)
- ActiveSupport::Notifications properly subscribed to catch rescued exceptions
- Background queue with timer-based flushing ensures data delivery
- Thread-safe context management with proper cleanup

This release makes ActiveRabbit production-ready for Rails applications with reliable exception tracking that works even when Rails rescues exceptions and renders error pages.

## [0.1.2] - 2024-12-20

### Added
- Initial release of ActiveRabbit Ruby client
- Error tracking with detailed context and stack traces
- Performance monitoring for database queries, controller actions, and custom operations
- N+1 query detection with automatic reporting
- PII scrubbing for sensitive data protection
- Rails integration with automatic middleware setup
- Sidekiq integration for background job monitoring
- HTTP client with request batching and retry logic
- Comprehensive configuration system
- Event tracking for custom application events
- Exception filtering and user agent filtering
- Before-send callbacks for events and exceptions
- Thread-safe operation with concurrent data structures
- Automatic environment detection
- Git release detection from various CI/CD platforms

### Features
- **Core Client**: Main client interface with configuration management
- **HTTP Client**: Faraday-based HTTP client with retry logic and batching
- **Event Processor**: Asynchronous event processing with queue management
- **Exception Tracker**: Comprehensive exception tracking with fingerprinting
- **Performance Monitor**: Performance metrics collection and transaction tracking
- **N+1 Detector**: Automatic detection of N+1 database query patterns
- **PII Scrubber**: Configurable PII detection and scrubbing
- **Rails Integration**: Automatic Rails middleware and notification subscribers
- **Sidekiq Integration**: Background job monitoring and error tracking

### Configuration
- Environment variable support for all major settings
- Configurable batching and flush intervals
- Feature toggles for performance monitoring and N+1 detection
- Customizable PII field patterns
- Exception and user agent filtering
- HTTP timeout and retry configuration

## [0.1.0] - 2024-01-16

### Added
- Initial gem structure and basic functionality
