require_relative "lib/lucid/case/version"

Gem::Specification.new do |spec|
  spec.name = "lucid-case"
  spec.version = Lucid::Case::VERSION
  spec.authors = ["Brazza Labs"]
  spec.summary = "Command and Query use cases for Rails with transactions, hooks, steps and caching"
  spec.description = "Lucid::Case is a use case library for Rails apps. Commands are transactional by default and " \
                     "run side effects after commit; Queries are read-only and cacheable by input."
  spec.homepage = "https://github.com/br4zz4/lucid-case"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2.0"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/CHANGELOG.md"
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.files = Dir["lib/**/*", "docs/**/*.md", "README.md", "CHANGELOG.md", "LICENSE"]
  spec.require_paths = ["lib"]

  spec.add_dependency "activejob", ">= 7.2", "< 9.0"
  spec.add_dependency "activemodel", ">= 7.2", "< 9.0"
  spec.add_dependency "activerecord", ">= 7.2", "< 9.0"
  spec.add_dependency "activesupport", ">= 7.2", "< 9.0"
end
