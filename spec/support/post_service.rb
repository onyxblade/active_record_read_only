# frozen_string_literal: true

class PostService
  include Post::Writable

  def self.create(attrs)
    Post.create!(attrs)
  end

  def self.update_title(post, title)
    post.update!(title: title)
  end

  def self.destroy(post)
    post.destroy!
  end

  def self.update_via_helper(post, title)
    UnregisteredHelper.touch(post, title)
  end

  def self.try_update_comment(comment, body)
    comment.update!(body: body)
  end

  def self.create_article(title)
    Article.create!(title: title)
  end

  def self.update_article(article, title)
    article.update!(title: title)
  end

  def self.create_private_note(title)
    PrivateNote.create!(title: title)
  end

  def self.update_private_note(note, title)
    note.update!(title: title)
  end

  def self.try_create_comment_via_assoc(post, body)
    post.comments.create!(body: body)
  end

  def self.try_create_comment_via_nested_attrs(post, body)
    post.update!(comments_attributes: [{body: body}])
  end

  def self.call_comment_service_to_create(post, body)
    CommentService.create_for_post(post, body)
  end

  def self.delegate_post_update_via_comment_service(post, title)
    CommentService.try_update_post(post, title)
  end

  def self.write_in_thread_block_here(post, title)
    Thread.new { post.update!(title: title) }.value
  end

  def self.write_in_thread_via_unregistered(post, title)
    UnregisteredHelper.run_in_thread(post, title)
  end

  def self.write_in_fiber_via_unregistered(post, title)
    UnregisteredHelper.run_in_fiber(post, title)
  end
end
