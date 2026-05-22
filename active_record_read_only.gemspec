# frozen_string_literal: true

require_relative "lib/active_record_read_only/version"

Gem::Specification.new do |spec|
  spec.name = "active_record_read_only"
  spec.version = ActiveRecordReadOnly::VERSION
  spec.authors = ["merely"]
  spec.email = ["git@merely.ca"]

  spec.summary = "Read-only-by-default ActiveRecord models, unlocked per file via `include Model::Writable`."
  spec.description = "Experimental gem that prepends a `readonly?` override into ActiveRecord models and grants write access only to files that include a per-model Writable marker. Enforcement is based on caller_locations at the moment AR checks readonly?. Not intended for production use."
  spec.homepage = "https://github.com/onyxblade/active_record_read_only"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2.0"
  spec.metadata["allowed_push_host"] = "https://rubygems.org"
  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/onyxblade/active_record_read_only"
  spec.metadata["changelog_uri"] = "https://github.com/onyxblade/active_record_read_only/blob/main/CHANGELOG.md"

  # Specify which files should be added to the gem when it is released.
  # The `git ls-files -z` loads the files in the RubyGem that have been added into git.
  gemspec = File.basename(__FILE__)
  spec.files = IO.popen(%w[git ls-files -z], chdir: __dir__, err: IO::NULL) do |ls|
    ls.readlines("\x0", chomp: true).reject do |f|
      (f == gemspec) ||
        f.start_with?(*%w[bin/ Gemfile .gitignore .rspec spec/])
    end
  end
  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  # Uncomment to register a new dependency of your gem
  # spec.add_dependency "example-gem", "~> 1.0"

  # For more information and examples about making a new gem, check out our
  # guide at: https://bundler.io/guides/creating_gem.html
end
