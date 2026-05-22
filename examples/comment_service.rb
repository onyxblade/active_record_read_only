# frozen_string_literal: true

class CommentService
  include Comment::Writable

  def self.create_for_post(post, body)
    post.comments.create!(body: body)
  end
end
