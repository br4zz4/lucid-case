# Lucid::Case

A use case library for Rails: a Case is a Command (writes) or a Query (reads), and every call returns a Result.

## Language

### Failures

**Fail-fast guard**:
A predicate declared with `fail_if` that, when true, ends the case with a typed failure and its Failure message before the body runs; guards run in declaration order and the first that holds wins.
_Avoid_: validation, precondition, rule

**Failure message**:
The human-readable text of a failure type, resolved by convention from the case name and the type through I18n.
_Avoid_: error string, failure reason

### Events

**Event**:
A business fact that a Command produced, published so other code can react without the Command knowing about it.
_Avoid_: notification, message, signal

**Case event**:
An Event recorded automatically for a Command call, named after the Command class, with no code in the Command.
_Avoid_: lifecycle event, auto event

**Custom event**:
An Event a Command emits explicitly from its body, with a name the author chooses.
_Avoid_: domain event, manual event

**Subscriber**:
A Case of the subscriber kind, or a named block, that reacts to Events; it is the only Case that can subscribe, and it never produces Events of its own.
_Avoid_: listener, handler, consumer, reaction

**Delivery**:
One Event handed to one Subscriber; an Event with three Subscribers has three Deliveries, each retried on its own.
_Avoid_: dispatch, execution

**Outbox**:
The table where Events are written in the same transaction as the Command's data, before anything delivers them.
_Avoid_: event store, queue

**Relay**:
The process that reads undelivered Events from the Outbox after commit and hands them to the Transport.
_Avoid_: dispatcher, publisher

**Transport**:
The destination the Relay delivers Events to: background jobs that run the Subscribers, or an external broker.
_Avoid_: adapter, bus, channel

**Instrumentation**:
The technical telemetry published for every call of any Case (`call.lucid_case`); it is not an Event and carries no business meaning.
_Avoid_: event (for this meaning)
