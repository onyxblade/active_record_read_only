# Why this gem uses `caller_locations` and not refinements

The original sketch for this gem was Ruby-idiomatic:

```ruby
class PostService
  using Post::Writable          # ← the unlock

  def self.publish(post)
    post.update!(published: true)
  end
end
```

A refinement called `Writable`, scoped lexically to the service file, would
flip the readonly bit. That is a normal use case for refinements: a
file-local behavior override. We ended up nowhere near that mechanism.
This doc explains why, with real Ruby output from
[`examples/why_refinements_dont_work.rb`](../examples/why_refinements_dont_work.rb).
To regenerate: `bundle exec ruby examples/why_refinements_dont_work.rb`.

## Attempt 1 — refinement overrides `readonly?`

The most direct mapping of the idea: make `Post#readonly?` return `true` by
default, and have `Post::Writable` be a refinement that overrides it to
return `false`. Inside a service that does `using Post::Writable`, the
refined `readonly?` is in effect, so when AR checks it before saving it
should see `false` and allow the write.

```ruby
class Post < ActiveRecord::Base
  def readonly?; true; end       # readonly by default
end

module PostWritableRefinement
  refine Post do
    def readonly?; false; end    # unlocked inside `using` scope
  end
end

class RefinementService
  using PostWritableRefinement

  def self.try_update
    post = Post.first
    puts "  Post#readonly? called directly from this file: #{post.readonly?.inspect}"
    post.update!(title: "via refinement service")
  end
end
```

Real output:

```
Attempt: Refinement override of readonly?
  Post#readonly? called directly from this file: false
  Result: ActiveRecord::ReadOnlyRecord raised
  AR's internal readonly? call did not see the refined method.
```

Note the two lines: when *we* call `post.readonly?` from inside the service
file, the refinement is active and it returns `false`. When AR calls
`self.readonly?` from inside `create_or_update`, the refinement is not
active and the original method (returning `true`) is used. AR raises
`ReadOnlyRecord`.

### Why

[Ruby's refinement spec][1] is explicit: refinements are activated at the
syntactic `using` call and remain active in the file/class/module scope
from that point forward. The activation is per **call site**, not per
receiver:

> When you write `obj.method`, Ruby looks at where in the source code that
> call appears. If the surrounding scope has `using SomeRefinement`, the
> refined method is considered. Otherwise it isn't.

AR's `update!` → `create_or_update` is regular Ruby code living in
`active_record/persistence.rb`. The call site for `self.readonly?` inside
that method is `persistence.rb:965`, which has no `using PostWritableRefinement`
anywhere in its lexical scope. The refinement might as well not exist.

[1]: https://docs.ruby-lang.org/en/master/syntax/refinements_rdoc.html

This is the same reason refinements cannot be used to "hook" framework
internals from outside the framework. They only affect code written under
the refinement's scope.

## Attempt 2 — monkey-patch `Module#using` so we can intercept it

If refining `readonly?` itself is useless, we still want to keep the
`using` syntax as a marker. The plan:

1. Override `Module#using` to detect when a "Writable" module is being
   `using`'d.
2. Record the caller file's path in a registry.
3. Forward to the real `Module#using` so any genuine refinement methods
   still get activated.

```ruby
class Module
  alias_method :__original_using__, :using
  private :__original_using__

  def using(mod)
    puts "  intercepted `using #{mod.inspect}` from #{caller_locations(1, 1).first.path}"
    __original_using__(mod)
  end
end

class WrapperService
  using PostWritableRefinement
end
```

Real output:

```
Attempt: Monkey-patch Module#using to intercept the call
  intercepted `using PostWritableRefinement` from examples/why_refinements_dont_work.rb
  Result: RuntimeError: Module#using is not permitted in methods
```

The interception part actually works — we get to log the calling file
path. The problem is the second line: forwarding to the real `using`
raises `RuntimeError: Module#using is not permitted in methods`.

### Why

MRI's implementation of `Module#using` checks the calling frame and
refuses to run if the caller is inside a method body. The check is in
[`vm_eval.c` / `rb_mod_using`][2]:

```c
if (previous_frame_is_method) {
    rb_raise(rb_eRuntimeError, "Module#using is not permitted in methods");
}
```

Our `def using(mod) ... __original_using__(mod) end` is a method, so when
the wrapper calls the original `using`, MRI sees the previous frame is a
method frame and rejects it.

[2]: https://github.com/ruby/ruby/blob/master/vm_eval.c

Even if Ruby allowed it, the refinement would activate on the **wrong
scope**. `using` activates the refinement on the `cref` of its caller —
i.e., on the lexical scope where `using` was syntactically invoked. From
inside our wrapper, that's the wrapper method's scope, not the original
user's `using Post::Writable` line. So even if MRI didn't raise, the
refinement wouldn't end up active in the user's class body.

This is fundamental: you cannot transparently wrap `using`. The mechanism
is tied to the source location of the call.

## What we settled on

Since the `using` syntax is unreachable both ways:

- Refining `readonly?` directly doesn't help (AR's call site is out of
  scope).
- Wrapping `using` to register the caller file isn't possible (Ruby
  refuses, and even if it didn't, the scope would be wrong).

…we abandoned refinements entirely and used what already worked:
`included` / `extended` hooks plus `caller_locations` at the moment AR
checks `readonly?`.

```ruby
class Post < AR::Base
  include ActiveRecordReadOnly       # prepends Behavior, defines Post::Writable
end

class PostService
  include Post::Writable             # included hook records this file's path
  def self.publish(post) = post.update!(published: true)
end
```

The DX cost compared to the original sketch is one keyword:
`include` instead of `using`. The semantic shift is real but small —
`include` is a class-body declaration that the file/class participates in
some protocol, which is exactly what we mean here. The mechanism cost is
real: we trade a (hypothetical) static refinement activation for a
runtime check that walks `caller_locations` on every `readonly?` call.

See [internals.md](internals.md) for a walk-through of how the runtime
check actually plays out, with real captured call stacks.

## Things we didn't try

- **TracePoint on `:c_call` for `Module#using`.** Could detect `using` invocations
  globally, but `:c_call` doesn't expose argument values, so we can't tell
  which file is unlocking which model. Plus the real `using` would still
  fail to activate the (now-pointless) refinement.

- **Refinement on the model `class << self`** so writes via class methods
  (`Post.create!`, `Post.update_all`) could be intercepted. Same lexical
  scope problem — AR calls those internally too.

- **A `Writable` real-module that prepends behavior on `included`.** If we
  prepend write helpers onto the calling class, anyone who includes it gets
  the ability — but then *any* `include Post::Writable` anywhere works,
  including from non-service files. The file-path filter is the part that
  makes it a privilege, not a capability anyone can ask for. (You could
  argue this is the right design and the file-path check is a poor man's
  capability check; this gem went the other way.)

- **Per-thread or per-fiber explicit `Writable.acquire { ... }`.** That's
  the block-wrapper design we explicitly didn't want, since the whole point
  was to keep service bodies syntactically normal.
