# frozen_string_literal: true

require_relative "lib/vaartix/version"

Gem::Specification.new do |spec|
  spec.name = "vaartix"
  spec.version = Vaartix::VERSION
  spec.authors = ["Vaartix"]
  spec.email = ["support@vaartix.com"]
  spec.summary = "The official Ruby client for Vaartix, the transactional email API built in India."
  spec.homepage = "https://vaartix.com"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.1"
  spec.metadata = {
    "source_code_uri" => "https://github.com/vaartix-mail/vaartix-ruby",
    "changelog_uri" => "https://github.com/vaartix-mail/vaartix-ruby/blob/main/CHANGELOG.md",
    "documentation_uri" => "https://vaartix.com/docs",
    "rubygems_mfa_required" => "true"
  }
  spec.files = Dir["lib/**/*.rb"] + %w[README.md LICENSE CHANGELOG.md]
  spec.require_paths = ["lib"]
end
