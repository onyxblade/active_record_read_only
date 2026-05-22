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
end
