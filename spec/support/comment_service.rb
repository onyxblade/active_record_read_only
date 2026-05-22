# frozen_string_literal: true

class CommentService
  include Comment::Writable

  def self.create(body)
    Comment.create!(body: body)
  end

  def self.update_body(comment, body)
    comment.update!(body: body)
  end

  def self.try_update_post(post, title)
    post.update!(title: title)
  end

  def self.create_for_post(post, body)
    post.comments.create!(body: body)
  end

  def self.call_post_service_to_update(post, title)
    PostService.update_title(post, title)
  end
end
