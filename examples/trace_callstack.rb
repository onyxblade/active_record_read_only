# frozen_string_literal: true

# Runs each scenario in README's "How it works" / "Limitations" sections and
# prints, for every readonly? check that fires:
#
#   - which model instance is being checked
#   - the caller_locations chain (AR internals collapsed for readability)
#   - the registry contents for that class
#   - the verdict (WRITABLE / READONLY)
#
# Designed to be re-runnable so doc/internals.md can quote real output.

require "bundler/setup"
require "active_record"
require "sqlite3"
require_relative "../lib/active_record_read_only"

ActiveRecord::Base.establish_connection(
  adapter: "sqlite3",
  database: "file::memory:?cache=shared",
  flags: SQLite3::Constants::Open::READWRITE |
         SQLite3::Constants::Open::CREATE |
         SQLite3::Constants::Open::URI
)

ActiveRecord::Schema.define do
  self.verbose = false
  create_table :posts, force: true do |t|
    t.string :title
  end
  create_table :comments, force: true do |t|
    t.integer :post_id
    t.string :body
  end
end

class Post < ActiveRecord::Base
  include ActiveRecordReadOnly
  has_many :comments, dependent: :destroy
end

class Comment < ActiveRecord::Base
  include ActiveRecordReadOnly
  belongs_to :post
end

require_relative "unregistered_helper"
require_relative "post_service"
require_relative "comment_service"

PROJECT_ROOT = File.expand_path("..", __dir__)

def short_path(path)
  return path unless path.start_with?(PROJECT_ROOT)
  path.sub(PROJECT_ROOT + "/", "")
end

def user_frame?(loc)
  return false unless loc.path
  return false if loc.path.include?("/gems/")
  return false if loc.path.start_with?("<") # internal
  loc.path.start_with?(PROJECT_ROOT)
end

# Instrument readonly? to log each invocation.
module CallStackTrace
  TRACE_LOG = []
  @enabled = false
  class << self
    attr_accessor :enabled
    alias_method :enabled?, :enabled
  end

  def readonly?
    if CallStackTrace.enabled?
      frames = caller_locations
      user_frames = frames.select { |l| l.path && !l.path.include?("/gems/") && !l.path.include?("/lib/ruby/") && l.path != "<internal:kernel>" }
      ar_count = frames.size - user_frames.size
      paths = ActiveRecordReadOnly::Registry.paths_for(self.class).map { |p|
        p.start_with?(PROJECT_ROOT) ? p.sub(PROJECT_ROOT + "/", "") : p
      }
      verdict = ActiveRecordReadOnly::Registry.caller_allowed?(self.class, caller_locations)
      TRACE_LOG << {
        klass: self.class.name,
        id: id,
        ar_frames: ar_count,
        user_frames: user_frames.map { |l| "#{short_path(l.path)}:#{l.lineno} in `#{l.label}`" },
        registered: paths,
        verdict: verdict ? "WRITABLE" : "READONLY"
      }
    end
    super
  end
end
ActiveRecordReadOnly::Behavior.prepend(CallStackTrace)

def run_scenario(label)
  puts
  puts "=" * 78
  puts "Scenario: #{label}"
  puts "=" * 78
  CallStackTrace::TRACE_LOG.clear
  CallStackTrace.enabled = true
  begin
    yield
    puts "Result: succeeded"
  rescue ActiveRecord::ReadOnlyRecord => e
    puts "Result: ActiveRecord::ReadOnlyRecord raised"
  rescue => e
    puts "Result: #{e.class}: #{e.message}"
  end
  CallStackTrace.enabled = false

  CallStackTrace::TRACE_LOG.each_with_index do |entry, i|
    puts
    puts "  readonly? check ##{i + 1}: #{entry[:klass]}(id=#{entry[:id].inspect})"
    puts "  caller chain (AR internals: #{entry[:ar_frames]} frames omitted):"
    entry[:user_frames].each { |f| puts "    #{f}" }
    puts "  registered paths for #{entry[:klass]}: #{entry[:registered].inspect}"
    puts "  verdict: #{entry[:verdict]}"
  end
end

# Seed a post via direct SQL so readonly? isn't tripped during setup.
ActiveRecord::Base.connection.insert("INSERT INTO posts (title) VALUES ('seed')")
SEED_POST_ID = Post.first.id

run_scenario "Direct write from a non-service file (this script)" do
  post = Post.find(SEED_POST_ID)
  post.update!(title: "direct")
end

run_scenario "Write from inside PostService" do
  post = Post.find(SEED_POST_ID)
  PostService.update_title(post, "via service")
end

run_scenario "PostService delegates to UnregisteredHelper" do
  post = Post.find(SEED_POST_ID)
  PostService.update_via_helper(post, "via helper")
end

run_scenario "PostService runs the write in Thread.new { ... } (block defined in PostService)" do
  post = Post.find(SEED_POST_ID)
  PostService.update_in_thread_block_here(post, "via thread")
end

Thread.report_on_exception = false
run_scenario "PostService delegates to UnregisteredHelper.run_in_thread (block defined in helper)" do
  post = Post.find(SEED_POST_ID)
  PostService.update_in_thread_via_unregistered(post, "blocked")
end
Thread.report_on_exception = true

run_scenario "Association write: post.comments.create! from PostService (only Post::Writable in scope)" do
  post = Post.find(SEED_POST_ID)
  PostService.try_create_comment_via_assoc(post, "comment from post service")
end

run_scenario "Association write: post.comments.create! from CommentService" do
  post = Post.find(SEED_POST_ID)
  CommentService.create_for_post(post, "comment from comment service")
end
