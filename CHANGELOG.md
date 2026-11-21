# Changelog

## 0.3.0

Fail-fast guards.

- `fail_if :predicate?` (or `fail_if(:type) { ... }`) ends a case with `failure(type, errors: [message])` before the body runs, with `as:`, `message:` and `with:`.
- `fail_with(:type, **content)` builds the same failure inside the body.
- The message is read from I18n by convention: `<case>.<type>`, then `lucid_case.failures.<type>`, then `type.to_s.humanize`.
- Guards run after `validates`, in declaration order, and the first one that holds wins. Logging shows which guard held.

Upgrading from 0.2.0: bump the tag and `bundle install`. Nothing changes until a case declares `fail_if`.

## 0.2.0

Events.

- `Lucid::Case::Subscriber` kind and `subscribe` (class macro, external call and `Lucid::Case.subscribe(..., as:) { }`), with `on:`, `step:` and `ordered:`.
- Case events for every recording Command, custom events with `emit`, step events for subscribed steps, `event_payload` and `events :enabled|:disabled`.
- `Lucid::Case::Event` and `config.events`.
- Transactional outbox (`lucid_case_events`), relay after commit, `Lucid::Case::Events.relay_pending` with retention and purge, `:inline` store, `:active_job` transport and custom transports (`publish(event)`).
- Opt-in deduplication of deliveries and ordered delivery per subscription.
- `stale_on` to drop query cache entries when an event happens.
- Event logging, `Lucid::Case::TestHelpers` and RSpec matchers (`lucid/case/rspec`), and `rails g lucid:case:events`.
- `activejob` is now a dependency.

Upgrading from 0.1.0: bump the tag and `bundle install`. Nothing changes until you turn events on: `config.events.recording` is `:disabled` by default. To use them, run `bin/rails g lucid:case:events`, migrate, and schedule `Lucid::Case::Events.relay_pending`.

## 0.1.0

Initial release.

- `Lucid::Case` base class with `attributes`, `.call`, `call!`, `success` and `failure`.
- `Lucid::Case::Result` with `type`, `content`, `[]`, `on_success`, `on_failure`, pattern matching and cache metadata.
- ActiveModel validations (`failure(:invalid_attributes, errors:)`) and `KindValidator` (`validates :x, kind: Hash`).
- `kind :command | :query`, `Lucid::Case::Command` (transactional by default, `transaction :disabled`) and `Lucid::Case::Query` (writes blocked with `while_preventing_writes`).
- Hooks: `after_success`, `after_failure`, `after_commit`.
- `step`, `continue`, `skip_to` and `catch`, with configurable content accumulation (`accumulate :enabled|:disabled`, `config.accumulate`).
- Opt-in cache for Queries: `cache`, `fresh`, `stale` (by inputs, by attribute names, or everything), `version`, `cached_at` / `expires_at`.
- `Lucid::Case.configure`, Railtie boot validation and `rails g lucid:case:install`.
- `call.lucid_case` instrumentation event.
- Optional logging of calls, steps, caught exceptions and results (`config.logging`, `logging :enabled|:disabled, values:` per case, keys only unless values are enabled), and `logger.info/warn/error/debug` inside cases.
- `finally(:name) { ... }`: cleanup that always runs after the case.
