# Internals: how the read-only check actually decides

This document walks through the mechanism with **real output captured from
`examples/trace_callstack.rb`**, not hand-written examples. To regenerate the
output yourself, run:

```bash
bundle exec ruby examples/trace_callstack.rb
```

The script defines two ActiveRecord models (`Post`, `Comment`), a registered
service (`PostService`), an unregistered helper, and a second registered
service for `Comment`. It instruments `ActiveRecordReadOnly::Behavior#readonly?`
to log the caller chain, the registry contents, and the verdict every time
ActiveRecord asks whether a record is read-only.

## The mechanism in one paragraph

`include ActiveRecordReadOnly` prepends a `Behavior` module that overrides
`readonly?`. The override grabs `caller_locations` and asks the per-class
registry: "is any frame on this stack from a file that did
`include Model::Writable`?" If yes, return `false` (writable). If no, return
`true` and let ActiveRecord raise `ActiveRecord::ReadOnlyRecord`. The registry
is populated at load time: when a service file does `include Post::Writable`,
the included hook captures the calling file path with `caller_locations(1, 8).find`
and stores it under `Post` in the registry. STI subclasses walk up the
superclass chain when looking up allowed paths.

## The setup used in the traces below

```ruby
# examples/post_service.rb
class PostService
  include Post::Writable                 # registers this file under Post

  def self.update_title(post, title)
    post.update!(title: title)
  end

  def self.update_via_helper(post, title)
    UnregisteredHelper.touch(post, title)
  end

  def self.update_in_thread_block_here(post, title)
    Thread.new { post.update!(title: title) }.value
  end

  def self.update_in_thread_via_unregistered(post, title)
    UnregisteredHelper.run_in_thread(post, title)
  end

  def self.try_create_comment_via_assoc(post, body)
    post.comments.create!(body: body)
  end
end

# examples/comment_service.rb
class CommentService
  include Comment::Writable              # registers this file under Comment

  def self.create_for_post(post, body)
    post.comments.create!(body: body)
  end
end

# examples/unregistered_helper.rb — does NOT include any Writable
class UnregisteredHelper
  def self.touch(post, title)
    post.update!(title: title)
  end

  def self.run_in_thread(post, title)
    Thread.new { post.update!(title: title) }.value
  end
end
```

After loading these files the registry contains:

```
Post     => ["examples/post_service.rb"]
Comment  => ["examples/comment_service.rb"]
```

---

## Scenario 1 — Direct write from a non-service file

The script itself (`examples/trace_callstack.rb`) is *not* registered as
writable. It calls `post.update!` directly.

```
Result: ActiveRecord::ReadOnlyRecord raised

  readonly? check #1: Post(id=1)
  caller chain (AR internals: 31 frames omitted):
    examples/trace_callstack.rb:130 in `block in <main>`
    examples/trace_callstack.rb:105 in `Object#run_scenario`
    examples/trace_callstack.rb:128 in `<main>`
  registered paths for Post: ["examples/post_service.rb"]
  verdict: READONLY
```

`trace_callstack.rb` is on the stack, but it isn't in `Post`'s registered
paths. No registered frame anywhere — verdict `READONLY`, AR raises.

## Scenario 2 — Write from inside PostService

The script calls `PostService.update_title(post, ...)`. `PostService`'s file
is registered for `Post`.

```
Result: succeeded

  readonly? check #1: Post(id=1)
  caller chain (AR internals: 31 frames omitted):
    examples/post_service.rb:7 in `PostService.update_title`
    examples/trace_callstack.rb:135 in `block in <main>`
    examples/trace_callstack.rb:105 in `Object#run_scenario`
    examples/trace_callstack.rb:133 in `<main>`
  registered paths for Post: ["examples/post_service.rb"]
  verdict: WRITABLE
```

`post_service.rb:7` is on the stack and matches a registered path → `WRITABLE`.

## Scenario 3 — Registered service delegates to an unregistered helper

`PostService.update_via_helper` calls `UnregisteredHelper.touch`, which is
where the actual `update!` happens. The helper file is *not* registered.

```
Result: succeeded

  readonly? check #1: Post(id=1)
  caller chain (AR internals: 31 frames omitted):
    examples/unregistered_helper.rb:5 in `UnregisteredHelper.touch`
    examples/post_service.rb:11 in `PostService.update_via_helper`
    examples/trace_callstack.rb:140 in `block in <main>`
    examples/trace_callstack.rb:105 in `Object#run_scenario`
    examples/trace_callstack.rb:138 in `<main>`
  registered paths for Post: ["examples/post_service.rb"]
  verdict: WRITABLE
```

The helper itself is not registered, but `PostService` is still on the stack
two frames up. The "any frame counts" rule says writable. **This is the design
trade-off**: it makes ordinary delegation work without ceremony, but it also
means a registered service implicitly grants its permission to anything it
calls into.

## Scenario 4 — Write inside `Thread.new { ... }` defined in the service

The block was written *inside* the service file. The thread's call stack
starts fresh, but the block's lexical source — `post_service.rb` — is the
frame at the bottom.

```
Result: succeeded

  readonly? check #1: Post(id=1)
  caller chain (AR internals: 31 frames omitted):
    examples/post_service.rb:15 in `block in PostService.update_in_thread_block_here`
  registered paths for Post: ["examples/post_service.rb"]
  verdict: WRITABLE
```

Only one user frame, in the registered file → `WRITABLE`. Threads do not
automatically lose the writable scope.

## Scenario 5 — Same write, but the block is defined in an unregistered helper

`PostService.update_in_thread_via_unregistered` calls
`UnregisteredHelper.run_in_thread`, which then does
`Thread.new { post.update!(...) }.value`. The block literal is in
`unregistered_helper.rb`. The new thread's stack only sees that file.

```
Result: ActiveRecord::ReadOnlyRecord raised

  readonly? check #1: Post(id=1)
  caller chain (AR internals: 31 frames omitted):
    examples/unregistered_helper.rb:9 in `block in UnregisteredHelper.run_in_thread`
  registered paths for Post: ["examples/post_service.rb"]
  verdict: READONLY
```

This is the realistic background-job analog. The original `PostService` frame
that triggered the queueing is on the *main* thread's stack, not the worker
thread's. From the worker's point of view, the registered file is gone.

**The rule:** what counts is whether the call stack *as it exists when AR
checks `readonly?`* includes a frame whose `path` is in the registry. Block
literals carry their lexical source as the `path` of their frame, so where
the block was written matters more than what thread it runs on.

## Scenario 6 — Association write from the wrong service

`PostService.try_create_comment_via_assoc` does `post.comments.create!`.
`PostService` is registered for `Post`, but the record being saved is a
`Comment`, and the registry for `Comment` only knows about
`comment_service.rb`.

```
Result: ActiveRecord::ReadOnlyRecord raised

  readonly? check #1: Comment(id=nil)
  caller chain (AR internals: 36 frames omitted):
    examples/post_service.rb:23 in `PostService.try_create_comment_via_assoc`
    examples/trace_callstack.rb:157 in `block in <main>`
    examples/trace_callstack.rb:105 in `Object#run_scenario`
    examples/trace_callstack.rb:155 in `<main>`
  registered paths for Comment: ["examples/comment_service.rb"]
  verdict: READONLY
```

`post_service.rb` is in the call stack, but the registry lookup is for
`Comment`, not `Post`. `Comment`'s allowed paths do not include
`post_service.rb` → `READONLY`. This is why each model needs its own
writable scope — having `Post::Writable` in scope does not unlock writes
through associations to other read-only models.

## Scenario 7 — Same association write, but from the right service

```
Result: succeeded

  readonly? check #1: Comment(id=nil)
  caller chain (AR internals: 36 frames omitted):
    examples/comment_service.rb:7 in `CommentService.create_for_post`
    examples/trace_callstack.rb:162 in `block in <main>`
    examples/trace_callstack.rb:105 in `Object#run_scenario`
    examples/trace_callstack.rb:160 in `<main>`
  registered paths for Comment: ["examples/comment_service.rb"]
  verdict: WRITABLE
```

`comment_service.rb` is in the call stack and in `Comment`'s allowed list
→ `WRITABLE`.

---

## What this implies about the design

- **Permission is granted per `(model_class, source_file)` pair.** The
  registry is a `Hash[Class => Set[String]]`. There is no notion of "who is
  calling whom" beyond the literal file paths on the stack.

- **`include Model::Writable` is load-time**, not call-time. The file path is
  captured once, in the `included` hook, and stored in the registry. The
  unlock has no runtime cost beyond a hash lookup.

- **STI inheritance walks the superclass chain.** When checking
  `readonly?` for a subclass instance, the registry tries `self.class`, then
  `self.class.superclass`, and so on. A parent's writable scope unlocks all
  subclasses; a subclass's own scope does not retroactively unlock the
  parent.

- **The check is O(frames × paths_per_class)** on every `readonly?` call.
  AR calls `readonly?` once per `save`/`update`/`destroy`. For most apps the
  registry has a handful of entries per model, and `caller_locations` returns
  a few dozen frames, so the overhead is sub-microsecond. Not free, though —
  worth knowing for hot loops.

- **There is no compile-time guarantee.** Anything that can put a frame from
  a registered file on the stack — `send`, `eval`, dynamically defined
  methods, blocks captured at load time — gets to write. The gem is a
  convention enforced at the same layer Rails enforces `readonly?`; it is
  not a security boundary.
