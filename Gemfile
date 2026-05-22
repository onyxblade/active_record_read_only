# frozen_string_literal: true

source "https://rubygems.org"

# Specify your gem's dependencies in active_record_read_only.gemspec
gemspec

gem "irb"
gem "rake", "~> 13.0"

gem "rspec", "~> 3.0"

group :development, :test do
  gem "activerecord", "~> 7.1"
  gem "sqlite3"
end

# Only needed to run examples/spike_debug_inspector.rb. Not installed by
# default — opt in with:
#   bundle config set --local with spike
#   bundle install
group :spike, optional: true do
  gem "debug_inspector"
end
