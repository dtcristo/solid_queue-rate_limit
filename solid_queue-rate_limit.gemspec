require_relative "lib/solid_queue/rate_limit/version"

Gem::Specification.new do |spec|
  spec.name        = "solid_queue-rate_limit"
  spec.version     = SolidQueue::RateLimit::VERSION
  spec.authors     = [ "David Cristofaro" ]
  spec.email       = [ "david@dtcristo.com" ]
  spec.homepage    = "https://github.com/dtcristo/solid_queue-rate_limit"
  spec.summary     = "Rate limits for Solid Queue jobs."
  spec.description = "Adds limits_rate to Active Job classes on Solid Queue. Workers admit a class's jobs no faster than the declared rate, and over-limit jobs wait as scheduled jobs without taking a worker thread."
  spec.license     = "MIT"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/dtcristo/solid_queue-rate_limit"
  spec.metadata["documentation_uri"] = "https://www.rubydoc.info/gems/solid_queue-rate_limit"
  spec.metadata["changelog_uri"] = "https://github.com/dtcristo/solid_queue-rate_limit/blob/main/CHANGELOG.md"

  spec.files = Dir.chdir(File.expand_path(__dir__)) do
    Dir["{app,lib}/**/*", "MIT-LICENSE", "README.md", "CHANGELOG.md", "UPGRADING.md"]
  end

  spec.required_ruby_version = ">= 3.2"

  # Patches private Solid Queue methods, so each new minor has to be tested first.
  spec.add_dependency "solid_queue", "~> 1.7.0"

  spec.add_development_dependency "appraisal"
  spec.add_development_dependency "debug", "~> 1.9"
  spec.add_development_dependency "minitest", "~> 5.0"
  spec.add_development_dependency "mocha"
  spec.add_development_dependency "mysql2"
  spec.add_development_dependency "pg"
  spec.add_development_dependency "sqlite3"
  spec.add_development_dependency "rubocop-rails-omakase"
  spec.add_development_dependency "solid_queue-coalesce", "~> 0.3.0"
  spec.add_development_dependency "rdoc"
  spec.add_development_dependency "logger"
end
