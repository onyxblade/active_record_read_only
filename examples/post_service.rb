# frozen_string_literal: true

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
