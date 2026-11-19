# Roadmap

Ideas under consideration. None of this is implemented or promised for a version.

## Circuit breaker

A `circuit_breaker` macro for cases that call unstable external services. After N consecutive failures of given exception classes the circuit opens, and the case returns `failure(:circuit_open)` without running its body. After a cool-down one call goes through as a probe, and a success closes the circuit again. The state would live in the configured cache store, scoped like the query cache.

## Other ideas

- Cache stampede protection (a lock, or stale-while-revalidate) for expensive queries.
- Invalidating by tag instead of by exact inputs.
- Retry policies for `catch` handlers.
- Async execution (`Case.call_later`) on top of ActiveJob.
- Instrumentation (`ActiveSupport::Notifications`) and a panel for pending or failed event deliveries.
- A test helper gem with `assert_success`, `assert_failure(:type)` and `stub_case`.
