# Errors

Errors raised by the gem inherit from `Lucid::Case::Error < StandardError`. Expected outcomes are `failure(...)` results, not errors.

| Error | When | Fix |
|---|---|---|
| `UnexpectedResult` | `call!` returned something other than `success` or `failure`; a step returned something other than `continue`, `skip_to`, `success` or `failure`; the steps ended without a final result. | Return `success(...)` or `failure(...)`. End a pipeline with a step that does. |
| `AmbiguousDefinition` | A class declares `step` and defines `call!`, in either order. Raised when the class loads. | Pick one. |
| `InvalidKind` | `kind` with something other than `:command`, `:query` or `:subscriber`, or redeclaring a different kind. | Declare the kind once. Do not change it in a subclass of `Command` or `Query`. |
| `SideEffectInQuery` | A query declares `transaction`, `after_success`, `after_failure` or `after_commit`, or `kind :query` comes after them. Raised when the class loads. | Make it a command, or move the side effect to the caller. |
| `CacheOnCommand` | `cache` on a command. | Declare `kind :query` (or inherit from `Query`) before `cache`, or drop `cache`. |
| `UncacheableInput` | A cached query got an input that cannot be keyed, such as an arbitrary object or a lambda. | Pass primitives, hashes and arrays of them, or records. |
| `CacheStoreMissing` | At boot, caching is in use, `perform_caching` is true and the store is `nil` or a `NullStore`. | Set `config.cache_store` to a real store, or set `perform_caching` to false. |
| `MissingCacheScope` | At boot, caching is in use and `cache_scope` is unset. Also at call time when the scope callable returns `nil`. | Set `config.cache_scope` to a callable or `:global`, and never return `nil` from it. |
| `SubscribeOutsideSubscriber` | `subscribe` in a command or a query. Raised when the class loads. | Make the class a `Lucid::Case::Subscriber`. |
| `InvalidSubscription` | A subscription with a target that is not a command, an unknown step, an invalid `on:`, `on:` or `step:` on a custom event, a block without `as:` when deduplication or `ordered:` is on, or `stale_on` outside a query. | Fix the declaration. |
| `EmitOutsideCommand` | `emit` in a query or a subscriber. | Emit from a command. |
| `UnserializableEvent` | The content or input of an event cannot be serialized (a lambda, a record that was not saved). | Pass primitives and saved records, or shape it with `event_payload`. |
| `RelayFailed` | `Lucid::Case::Events.relay_pending` finished a batch in which a transport failed. The message lists the event ids. | Fix the transport; the rows stay pending and the next sweep retries. |

A few errors come from elsewhere:

- `ActiveRecord::ReadOnlyError`: a query tried to write. Make it a command.
- `ArgumentError`: invalid `transaction`, `cache`, `accumulate` or `logging` value, `catch` without classes or a block, a hook without a method or block, a `step` without a block, `skip_to` a step that is not ahead, `fail_if` without a name, a block guard named with `?`, `fail_if` with `as:` and a block, an invalid `with:` or one that includes `:errors`, or `fail_with` with `errors:` in the content. See [Guards](guards.md).
- `NotImplementedError`: a case with neither `call!` nor steps.
- `NoMethodError`: `fresh` or `stale` on a command.
