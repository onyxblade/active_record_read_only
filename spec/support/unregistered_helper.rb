# frozen_string_literal: true

class UnregisteredHelper
  def self.touch(post, title)
    post.update!(title: title)
  end

  def self.run_in_thread(post, title)
    Thread.new { post.update!(title: title) }.value
  end

  def self.run_in_fiber(post, title)
    fiber = Fiber.new { post.update!(title: title) }
    fiber.resume
  end
end
