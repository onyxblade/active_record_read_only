# frozen_string_literal: true

class BothService
  include Post::Writable
  include Comment::Writable

  def self.update_post(post, title)
    post.update!(title: title)
  end

  def self.update_comment(comment, body)
    comment.update!(body: body)
  end
end
