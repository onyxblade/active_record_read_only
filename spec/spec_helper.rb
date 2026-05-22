# frozen_string_literal: true

require "active_record"
require "sqlite3"
require "active_record_read_only"

ActiveRecord::Base.establish_connection(
  adapter: "sqlite3",
  database: "file::memory:?cache=shared",
  flags: SQLite3::Constants::Open::READWRITE | SQLite3::Constants::Open::CREATE | SQLite3::Constants::Open::URI
)

ActiveRecord::Schema.define do
  create_table :posts, force: true do |t|
    t.string :type
    t.string :title
    t.string :body
  end

  create_table :comments, force: true do |t|
    t.integer :post_id
    t.string :body
  end
end

class Post < ActiveRecord::Base
  include ActiveRecordReadOnly
  has_many :comments, dependent: :destroy
  accepts_nested_attributes_for :comments
end

class Comment < ActiveRecord::Base
  include ActiveRecordReadOnly
  belongs_to :post
end

class Article < Post
end

class PrivateNote < Post
  include ActiveRecordReadOnly
end

require_relative "support/unregistered_helper"
require_relative "support/post_service"
require_relative "support/comment_service"
require_relative "support/both_service"
require_relative "support/private_note_service"

RSpec.configure do |config|
  config.example_status_persistence_file_path = ".rspec_status"
  config.disable_monkey_patching!

  config.expect_with :rspec do |c|
    c.syntax = :expect
  end

  config.before(:each) do
    Comment.delete_all
    Post.delete_all
  end
end
