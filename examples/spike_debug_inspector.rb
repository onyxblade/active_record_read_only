# frozen_string_literal: true

# Spike: class-identity-based read-only check using RubyVM::DebugInspector.
#
# Differences from the production design in lib/active_record_read_only.rb:
#   - Registry stores the *authorized class*, not a file path.
#   - readonly? walks frames via DebugInspector and matches frame_class
#     against the authorized set instead of comparing path strings.
#   - "Borrowing" still works (any frame on the stack belonging to an
#     authorized class counts), but the trigger is class identity.
#
# `debug_inspector` is in the optional `:spike` bundler group, not installed
# by default. To run this script:
#
#   bundle config set --local with spike
#   bundle install
#   bundle exec ruby examples/spike_debug_inspector.rb
#
# To go back to the default (skip the C extension):
#
#   bundle config unset --local with
#   bundle install

require "bundler/setup"
require "active_record"
require "sqlite3"
require "debug_inspector"
require "set"
require "benchmark"

# -------------------------------------------------------------------------
# The alternative library, inlined.
# -------------------------------------------------------------------------

module ARROClassBased
  module Registry
    @allowed = Hash.new { |h, k| h[k] = Set.new }
    class << self
      def allow(model_klass, authorized_klass)
        @allowed[model_klass] << authorized_klass
        # Also store the singleton class so `def self.foo` frames match.
        @allowed[model_klass] << authorized_klass.singleton_class
      end

      def authorized_for(model_klass)
        @allowed[model_klass]
      end
    end
  end

  module Behavior
    def readonly?
      target = self.class
      until target.nil?
        allowed = Registry.authorized_for(target)
        unless allowed.empty?
          RubyVM::DebugInspector.open do |dc|
            n = dc.backtrace_locations.size
            (0...n).each do |i|
              frame_klass = begin
                dc.frame_class(i)
              rescue ArgumentError
                nil
              end
              next if frame_klass.nil?
              return false if allowed.include?(frame_klass)
            end
          end
        end
        target = target.respond_to?(:superclass) ? target.superclass : nil
      end
      true
    end
  end

  def self.included(model_klass)
    model_klass.prepend(Behavior)
    marker = Module.new
    marker.define_singleton_method(:included) do |base|
      Registry.allow(model_klass, base)
    end
    model_klass.const_set(:Writable, marker)
  end
end

# -------------------------------------------------------------------------
# Setup
# -------------------------------------------------------------------------

ActiveRecord::Base.establish_connection(
  adapter: "sqlite3",
  database: "file::memory:?cache=shared",
  flags: SQLite3::Constants::Open::READWRITE |
         SQLite3::Constants::Open::CREATE |
         SQLite3::Constants::Open::URI
)

ActiveRecord::Schema.define do
  self.verbose = false
  create_table(:posts, force: true) { |t| t.string :title }
  create_table(:comments, force: true) { |t| t.integer :post_id; t.string :body }
end

class Post < ActiveRecord::Base
  include ARROClassBased
  has_many :comments, dependent: :destroy
end

class Comment < ActiveRecord::Base
  include ARROClassBased
  belongs_to :post
end

class UnregisteredHelper
  def self.touch(post, title)
    post.update!(title: title)
  end

  def self.run_in_thread(post, title)
    Thread.new { post.update!(title: title) }.value
  end
end

class PostService
  include Post::Writable

  def self.update_title(post, title)
    post.update!(title: title)
  end

  def self.update_via_helper(post, title)
    UnregisteredHelper.touch(post, title)
  end

  def self.update_in_thread_block_here(post, title)
    Thread.new { post.update!(title: title) }.value
  end

  def self.update_in_thread_via_unregistered(post, title)
    UnregisteredHelper.run_in_thread(post, title)
  end

  def self.try_create_comment_via_assoc(post, body)
    post.comments.create!(body: body)
  end
end

class CommentService
  include Comment::Writable

  def self.create_for_post(post, body)
    post.comments.create!(body: body)
  end
end

ActiveRecord::Base.connection.insert("INSERT INTO posts (title) VALUES ('seed')")
SEED_ID = Post.first.id

def banner(label)
  puts
  puts "=" * 78
  puts "Scenario: #{label}"
  puts "=" * 78
end

def run(label)
  banner(label)
  yield
  puts "Result: succeeded"
rescue ActiveRecord::ReadOnlyRecord
  puts "Result: ActiveRecord::ReadOnlyRecord raised"
rescue => e
  puts "Result: #{e.class}: #{e.message}"
end

Thread.report_on_exception = false

run("Direct write from a non-service file") do
  Post.find(SEED_ID).update!(title: "direct")
end

run("Write from inside PostService") do
  PostService.update_title(Post.find(SEED_ID), "via service")
end

run("PostService delegates to UnregisteredHelper") do
  PostService.update_via_helper(Post.find(SEED_ID), "via helper")
end

run("Thread block defined in PostService") do
  PostService.update_in_thread_block_here(Post.find(SEED_ID), "via thread")
end

run("Thread block defined in UnregisteredHelper") do
  PostService.update_in_thread_via_unregistered(Post.find(SEED_ID), "blocked")
end

run("Association write from PostService (Post::Writable only)") do
  PostService.try_create_comment_via_assoc(Post.find(SEED_ID), "x")
end

run("Association write from CommentService") do
  CommentService.create_for_post(Post.find(SEED_ID), "ok")
end

# -------------------------------------------------------------------------
# Micro-benchmark: readonly? check on a hot loop, class-based vs path-based.
# -------------------------------------------------------------------------

# Re-implement the path-based check inline so both run in the same process
# without loading the real gem (which would clash on Post#readonly?).

module PathBasedCheck
  @paths = Set.new([File.expand_path(__FILE__)])
  def self.allowed?(locations)
    locations.any? { |l| l.path && @paths.include?(l.path) }
  end
end

post = Post.find(SEED_ID)

puts
puts "=" * 78
puts "Micro-benchmark: 100k readonly?-style checks from the same call site"
puts "=" * 78

ITER = 100_000

# Pre-warm
1000.times { post.readonly? }
1000.times { PathBasedCheck.allowed?(caller_locations) }

Benchmark.bm(28) do |x|
  x.report("DebugInspector (class-id):") do
    ITER.times { post.readonly? }
  end
  x.report("caller_locations (paths):") do
    ITER.times { PathBasedCheck.allowed?(caller_locations) }
  end
end
