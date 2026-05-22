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

  def self.create_post_with_comments(title, comment_bodies)
    Post.create!(title: title, comments_attributes: comment_bodies.map { |b| {body: b} })
  end
end
