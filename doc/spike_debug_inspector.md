# Spike: replace path matching with class identity via `RubyVM::DebugInspector`

The production design (see [`internals.md`](internals.md)) makes the
read-only decision by walking `caller_locations` and comparing string
**paths** to a registry. A reviewer asked the obvious follow-up: could we
do it with class **identity** instead — `frame_class == PostService` —
and skip the text compare entirely?

The blocker is that Ruby's standard backtrace API (`Kernel#caller`,
`caller_locations`) doesn't expose the class of each frame. To get that,
you need a C extension. The `debug_inspector` gem ships exactly that API:

```ruby
RubyVM::DebugInspector.open do |dc|
  dc.frame_class(i)    # → defined_class of frame i
  dc.frame_binding(i)  # → binding of frame i
end
```

This doc reports a working spike, with real captured output and a
benchmark, and explains why we are **not adopting it**.

## How the spike works

[`examples/spike_debug_inspector.rb`](../examples/spike_debug_inspector.rb)
is a self-contained alternative implementation:

- `Registry` stores `Hash[Model => Set[AuthorizedClass]]`. The `included`
  hook on `Model::Writable` records `base` (the calling class) and
  `base.singleton_class` — the singleton form is needed because frames
  for `def self.foo` carry `#<Class:Service>` as their `frame_class`,
  not the class itself.
- `Behavior#readonly?` opens a `DebugInspector`, walks `frame_class(i)`
  for every frame, and returns `false` on the first identity match.
  STI's superclass walk works the same way as the production design.

The user-facing API doesn't change: `include ActiveRecordReadOnly` on
the model, `include Post::Writable` on the service.

## Behavior matches the production design

Same seven scenarios as `examples/trace_callstack.rb`, run against the
class-identity version. Real output:

```
Scenario: Direct write from a non-service file
Result: ActiveRecord::ReadOnlyRecord raised

Scenario: Write from inside PostService
Result: succeeded

Scenario: PostService delegates to UnregisteredHelper
Result: succeeded

Scenario: Thread block defined in PostService
Result: succeeded

Scenario: Thread block defined in UnregisteredHelper
Result: ActiveRecord::ReadOnlyRecord raised

Scenario: Association write from PostService (Post::Writable only)
Result: ActiveRecord::ReadOnlyRecord raised

Scenario: Association write from CommentService
Result: succeeded
```

All seven verdicts agree with the path-based version, including the
two subtle cases:

- **Thread block defined in PostService → succeeded.** The block's
  `frame_class` in the new thread's stack is `#<Class:PostService>`
  (the singleton class), which is in the registry. The lexical-source
  rule survives, just through identity instead of paths.
- **Thread block defined in UnregisteredHelper → raised.** Same as
  before, no registered class is on the worker thread's stack.

## Benchmark

100,000 `readonly?` calls in a tight loop on the same call site, same
Ruby (4.0.0 dev), same process:

```
                                   user     system      total        real
DebugInspector (class-id):     0.386448   0.002970   0.389418 (  0.390722)
caller_locations (paths):      0.097818   0.001989   0.099807 (  0.100126)
```

About **3.9× slower** per check (~3.9 µs vs ~1.0 µs). Still microsecond
range — for a Rails request that touches a few records, the overhead is
invisible. For a bulk loop touching tens of thousands of records the
difference becomes noticeable. AR doesn't usually do that, but
`update_all` and friends already bypass `readonly?` anyway, so the
realistic workload tilts toward "fine in both cases".

The cost is dominated by `DebugInspector.open` itself, which sets up
some VM-level state on every call. It's not the frame walk — that part
is fast.

## Why we are not adopting it

Despite being technically cleaner, the spike isn't going into the gem:

- **C extension dependency.** `debug_inspector` is a compiled gem with
  its own platform-specific binary. For a gem that today depends on
  nothing but `activerecord`, taking on a native build dependency to
  move from "string compare" to "class compare" is a bad trade. The
  failure modes of "compile failed on this platform / Ruby ABI changed"
  outweigh the elegance.

- **`DebugInspector.open` overhead is ~4× per call.** This is small in
  absolute terms but it pays the cost on every save. The path-based
  check is already negligible, and trading negligible-and-no-deps for
  also-negligible-but-needs-native-extension is a net loss.

- **`debug_inspector` is a debugging tool.** Its purpose is to support
  things like `pry`, `binding_of_caller`, exception handlers — code
  that runs rarely and wants full introspection. Calling it on every
  AR save inverts that usage pattern. It works, but it's outside the
  intended envelope.

- **The path comparison is honest about the trick.** Caller-locations
  + path matching makes obvious that this is a "what file is on the
  stack" check. Switching to class identity would make the mechanism
  feel more principled than it actually is, while not changing any of
  the actual guarantees (still no compile-time check, still based on
  "any frame counts", still defeatable by anything that can put a
  registered frame on the stack).

## How to reproduce

`debug_inspector` is in the optional `:spike` Bundler group, not
installed by default. To run the spike yourself:

```bash
bundle config set --local with spike
bundle install
bundle exec ruby examples/spike_debug_inspector.rb
```

To go back to the default (skip the C extension):

```bash
bundle config unset --local with
bundle install
```
