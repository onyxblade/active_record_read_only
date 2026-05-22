# frozen_string_literal: true

require "active_record"
require "active_record_read_only"

ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")

ActiveRecord::Schema.define do
  create_table :posts, force: true do |t|
    t.string :title
    t.string :body
  end

  create_table :comments, force: true do |t|
    t.string :body
  end
end

class Post < ActiveRecord::Base
  include ActiveRecordReadOnly::Setup
end

class Comment < ActiveRecord::Base
  include ActiveRecordReadOnly::Setup
end

require_relative "support/unregistered_helper"
require_relative "support/post_service"
require_relative "support/comment_service"
require_relative "support/both_service"

RSpec.configure do |config|
  config.example_status_persistence_file_path = ".rspec_status"
  config.disable_monkey_patching!

  config.expect_with :rspec do |c|
    c.syntax = :expect
  end

  config.before(:each) { Post.delete_all }
end
