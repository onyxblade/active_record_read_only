# frozen_string_literal: true

class PrivateNoteService
  include PrivateNote::Writable

  def self.create(title)
    PrivateNote.create!(title: title)
  end

  def self.update_title(note, title)
    note.update!(title: title)
  end

  def self.try_update_post(post, title)
    post.update!(title: title)
  end

  def self.try_update_article(article, title)
    article.update!(title: title)
  end
end
