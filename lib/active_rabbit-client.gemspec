# frozen_string_literal: true
require_relative "lib/active_rabbit/client/version"

Gem::Specification.new do |spec|
  spec.name          = "active_rabbit"
  spec.version       = ActiveRabbit::Client::VERSION
  spec.authors       = ["ActiveRabbit"]
  spec.email         = ["support@activerabbit.ai"]

  spec.summary       = "Error tracking, performance monitoring and deploy tracking"
  spec.description   = "ActiveRabbit client gem for error tracking, performance monitoring and deploy tracking."
  spec.homepage      = "https://github.com/activerabbit-ai/activerabbit-ai"
  spec.license       = "MIT"

  spec.required_ruby_version = ">= 3.0"

  spec.files = Dir.glob(
    [
      "lib/**/*",
      "README.md",
      "LICENSE"
    ]
  )

  spec.require_paths = ["lib"]

  spec.add_dependency "concurrent-ruby"
end
