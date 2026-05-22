# ActiveRecordReadOnly

Make an ActiveRecord model read-only by default, and only allow writes from
specific service classes. No block wrappers, no `with_writable do ... end` —
just `include Model::Writable` at the top of the file that should be allowed
to write, and the rest of the code in that file behaves normally.

```ruby
class Post < ApplicationRecord
  include ActiveRecordReadOnly
end

# Anywhere else in the codebase — blocked
Post.find(1).update!(title: "x")
# => ActiveRecord::ReadOnlyRecord

# In a service class — allowed
class PostService
  include Post::Writable

  def self.publish(post)
    post.update!(published: true)   # works
  end
end
```

## How it works

`include ActiveRecordReadOnly` does two things to the model:

1. Prepends a module that overrides `readonly?` to return `true` by default.
2. Defines a per-class marker constant `Model::Writable`.

`include Model::Writable` in another class triggers an `included` hook that
records the calling file's path in a per-class registry.

When ActiveRecord checks `readonly?` before saving, the prepended module walks
`caller_locations` and returns `false` if any frame on the call stack lives in
a file that included `Model::Writable`. Otherwise it returns `true` and AR
raises `ActiveRecord::ReadOnlyRecord`.

The registry walks the model's superclass chain on lookup, so STI subclasses
inherit their parent's writable scopes.

## Installation

Add to your Gemfile:

```ruby
gem "active_record_read_only", github: "onyxblade/active_record_read_only"
```

## Usage

### Mark a model read-only

```ruby
class Post < ApplicationRecord
  include ActiveRecordReadOnly
end
```

`Post` instances now raise `ActiveRecord::ReadOnlyRecord` on any write path
that goes through `readonly?` — `save`, `save!`, `update`, `update!`,
`destroy`, `destroy!`, `update_columns`, `touch`, `Post.create!`, etc.

### Unlock writes from a specific file

```ruby
class PostService
  include Post::Writable

  def self.publish(post)
    post.update!(published: true)
  end
end
```

Every method in `post_service.rb` is now allowed to write `Post` records.
The unlock is per file, not per class — splitting `PostService` across
multiple files means each file needs its own `include Post::Writable`.

### Per-class isolation

`include Post::Writable` does not grant write permission for other models.
Including multiple Writable modules is fine:

```ruby
class ReportService
  include Post::Writable
  include Comment::Writable
end
```

### STI

Subclasses inherit `readonly?` from the parent automatically. If a subclass
needs its own write scope, include `ActiveRecordReadOnly` on the subclass too:

```ruby
class Post < ApplicationRecord
  include ActiveRecordReadOnly
end

class Article < Post
  # inherits readonly + uses Post::Writable for unlocking
end

class PrivateNote < Post
  include ActiveRecordReadOnly
  # gets its own PrivateNote::Writable constant
end
```

`include Post::Writable` allows writing any subclass (registry walks up the
superclass chain). `include PrivateNote::Writable` only allows writing
`PrivateNote`, not `Post` or sibling subclasses.

## Limitations

The check is based on `caller_locations`. The rule is: **at the moment AR
calls `readonly?`, is any frame on the current thread/fiber's stack from a
file that did `include Model::Writable`?**

This has predictable consequences:

- **Background jobs / threads where the unlock file is not on the stack.**
  If a service enqueues an ActiveJob and the worker thread executes the
  perform method later, the original service is no longer on the stack. The
  job's `perform` file must itself `include Model::Writable`.

- **Block source matters, not "did you cross a thread boundary".** Writing
  inside `Thread.new { post.update!(...) }` from a registered service still
  works, because the block's lexical source is the registered file and shows
  up in the new thread's stack. But the same code spawned from inside an
  unregistered helper loses the scope.

- **Borrowing.** If service A (registered for `Post`) calls a method on
  service B that tries to write a `Post`, the write succeeds — A is still on
  the stack. Useful in practice, but worth knowing when reviewing service
  boundaries.

- **Rails escape hatches are not patched.** `Post.update_all`,
  `Post.delete_all`, and `record.delete` bypass `readonly?` by design in
  ActiveRecord. They keep working without any service context. This gem only
  enforces the read-only contract at the same layer Rails enforces it.

- **`eval`'d code paths.** Code evaluated via `eval` shows up in
  `caller_locations` with a path like `(eval at ...)`, which never matches a
  registered file. The surrounding service frame is usually still on the
  stack, so this rarely matters in practice.

## Development

```bash
bundle install
bundle exec rspec
```

The spec suite boots a real ActiveRecord + sqlite3 in-memory database and
exercises the read-only enforcement against actual `save`, `update!`,
`destroy!`, association writes, nested attributes, STI subclasses, and
multi-service / cross-thread scenarios.

## Contributing

Bug reports and pull requests are welcome at
https://github.com/onyxblade/active_record_read_only.

## License

The gem is available as open source under the terms of the
[MIT License](https://opensource.org/licenses/MIT).
