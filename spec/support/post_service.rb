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
end
