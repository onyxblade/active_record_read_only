# frozen_string_literal: true

# Minimal reproductions of the two refinement-based designs we tried before
# settling on caller_locations. Each `Attempt` is self-contained and either
# prints what it observed or raises — we quote the real output in
# doc/design_choices.md.

require "bundler/setup"
require "active_record"
require "sqlite3"

ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")
ActiveRecord::Schema.define do
  self.verbose = false
  create_table(:posts) { |t| t.string :title }
end

class Post < ActiveRecord::Base
end

ActiveRecord::Base.connection.insert("INSERT INTO posts (title) VALUES ('seed')")

def banner(label)
  puts
  puts "=" * 78
  puts "Attempt: #{label}"
  puts "=" * 78
end

# -----------------------------------------------------------------------------
# Attempt 1: a refinement that overrides `readonly?` to return false.
#
# Intuition: services do `using Post::Writable`, refinement is active in that
# file, so `record.update!` inside the service should see the refined
# `readonly?` and return false.
#
# Reality: refinements only activate at the lexical *call site*. AR's
# `update!` calls `self.readonly?` from inside the AR gem's source. That call
# site is not in the service's file, so the refinement is not active there,
# and the refined `readonly?` is never consulted.
# -----------------------------------------------------------------------------

banner("Refinement override of readonly?")

class Post
  def readonly?
    true
  end
end

module PostWritableRefinement
  refine Post do
    def readonly?
      false
    end
  end
end

class RefinementService
  using PostWritableRefinement

  def self.try_update
    post = Post.first
    # In *this* file, refinement is active.
    puts "  Post#readonly? called directly from this file: #{post.readonly?.inspect}"
    # But AR calls readonly? from inside the gem, where the refinement is NOT active.
    post.update!(title: "via refinement service")
  end
end

begin
  RefinementService.try_update
  puts "  Result: succeeded (refinement worked through AR)"
rescue ActiveRecord::ReadOnlyRecord => e
  puts "  Result: #{e.class} raised"
  puts "  AR's internal readonly? call did not see the refined method."
end

# Clean up Post#readonly? for the next attempt.
class Post
  remove_method :readonly?
end

# -----------------------------------------------------------------------------
# Attempt 2: monkey-patch Module#using to register the caller's file.
#
# Intuition: keep `using Post::Writable` as the user-facing syntax, but
# intercept the `using` call to record which file did it. The interception
# wrapper would also forward to the real `using` so any actual refinement
# methods still get activated.
#
# Reality: Ruby explicitly forbids calling `using` from inside a method body
# ("Module#using is not permitted in methods"). Our wrapper IS a method, so
# the moment it calls the real `using`, MRI raises RuntimeError.
# -----------------------------------------------------------------------------

banner("Monkey-patch Module#using to intercept the call")

class Module
  alias_method :__original_using__, :using
  private :__original_using__

  def using(mod)
    puts "  intercepted `using #{mod.inspect}` from #{caller_locations(1, 1).first.path}"
    __original_using__(mod) # <-- explodes here
  end
end

class WrapperService
  begin
    using PostWritableRefinement
    puts "  Result: using succeeded"
  rescue RuntimeError => e
    puts "  Result: RuntimeError: #{e.message}"
  end
end

# Restore the original `using` so the rest of the file behaves normally.
class Module
  alias_method :using, :__original_using__
end
