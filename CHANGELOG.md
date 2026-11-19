# Changelog

## Unreleased

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
