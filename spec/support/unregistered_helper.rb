# frozen_string_literal: true

class UnregisteredHelper
  def self.touch(post, title)
    post.update!(title: title)
  end
end
