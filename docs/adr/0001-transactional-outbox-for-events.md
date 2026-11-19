# 1. Transactional outbox as the default event store

Date: 2026-11-19

## Status

Accepted

## Context

Commands publish Events that other code reacts to. The Event must exist if and only if the Command's data was committed. There is no atomic commit across the database and a broker (SQS, RabbitMQ) or a job queue: publishing inside the transaction creates phantom events on rollback, and publishing after commit loses the event if the process dies in between.

## Decision

Events are written to an Outbox table (`lucid_case_events`) in the same transaction as the Command's data. A Relay reads undelivered rows after commit and hands them to a pluggable Transport (`:active_job` by default; an external broker through an adapter written by the app). A periodic sweep re-relays rows left behind by a crash and purges delivered rows after a configurable retention. Delivery is at-least-once; each Event carries a UUID for idempotency, and deduplication per Subscriber is available opt-in.

An `:inline` store (no table, in-process delivery after commit, at-most-once) exists for apps without the migration and for tests.

## Consequences

- Apps that use events need a migration from the gem's generator; events are off until the app turns them on.
- "The event follows the data": an Event written inside a transaction disappears with its rollback, with no extra code. Steps of a case with `transaction :disabled` publish even if a later step fails.
- Subscribers must be idempotent or enable deduplication.
- Brokers are only Transports; their adapters live in the app, so the gem has no dependency on `aws-sdk` or `bunny`.
