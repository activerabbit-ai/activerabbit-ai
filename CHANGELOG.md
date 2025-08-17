# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- Initial release of ActiveAgent Ruby client
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
