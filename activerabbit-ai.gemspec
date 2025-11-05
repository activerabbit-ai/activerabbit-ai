# frozen_string_literal: true

require_relative "lib/active_rabbit/client/version"

Gem::Specification.new do |spec|
  spec.name = "activerabbit-ai"
  spec.version = ActiveRabbit::Client::VERSION
  spec.authors = ["Alex Shapalov"]
  spec.email = ["shapalov@gmail.com"]

  spec.summary = "Ruby client for ActiveRabbit.ai application monitoring and error tracking"
  spec.description = "A comprehensive Ruby client for ActiveRabbit.ai that provides error tracking, performance monitoring, and application observability for Rails applications."
  spec.homepage = "https://github.com/bugrabbit/active_rabbit-client"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.1.0"

  spec.metadata["allowed_push_host"] = "https://rubygems.org"

  spec.metadata["source_code_uri"] = "https://github.com/bugrabbit/active_rabbit-client"
  spec.metadata["changelog_uri"] = "https://github.com/bugrabbit/active_rabbit-client/blob/main/CHANGELOG.md"

  # Specify which files should be added to the gem when it is released.
  # The `git ls-files -z` loads the files in the RubyGem that have been added into git.
  gemspec = File.basename(__FILE__)
  spec.files = IO.popen(%w[git ls-files -z], chdir: __dir__, err: IO::NULL) do |ls|
    ls.readlines("\x0", chomp: true).reject do |f|
      (f == gemspec) ||
        f.start_with?(*%w[bin/ test/ spec/ features/ .git .github appveyor Gemfile])
    end
  end
  spec.files << "lib/activerabbit-ai.rb" unless spec.files.include?("lib/activerabbit-ai.rb")

  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  # Runtime dependencies
  spec.add_dependency "concurrent-ruby", "~> 1.1"

  # Development dependencies
  spec.add_development_dependency "rspec", "~> 3.0"
  spec.add_development_dependency "webmock", "~> 3.0"
  spec.add_development_dependency "standard", "~> 1.0"

  # For more information and examples about making a new gem, check out our
  # guide at: https://bundler.io/guides/creating_gem.html
end
