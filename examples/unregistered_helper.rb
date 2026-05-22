# frozen_string_literal: true

class UnregisteredHelper
  def self.touch(post, title)
    post.update!(title: title)
  end

  def self.run_in_thread(post, title)
    Thread.new { post.update!(title: title) }.value
  end
end
