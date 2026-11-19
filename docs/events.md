# Events

A command can publish what happened, and other code can react without the command knowing about it. Events are written in the same transaction as the command's data, so an event exists if and only if the data does.

Events are off until you turn them on:

```sh
bin/rails g lucid:case:events
bin/rails db:migrate
```

The generator creates the migrations for `lucid_case_events` and `lucid_case_deliveries`, and `config/initializers/lucid_case_events.rb` with `recording = :enabled`, the `:outbox` store (and `:inline` in the test environment) and every other option commented with its default. Without the migration, keep `config.events.recording = :disabled` (the default).

## Case events

Every command that records produces a **Case event** when it finishes, named after the class: `Enrollment::Approve` becomes `enrollment.approve`. Nothing to write in the command.

```ruby
class Enrollment::Approve < Lucid::Case::Command
  attributes :enrollment

  def call!
    enrollment.update!(status: :approved)
    success(enrollment: enrollment)
  end
end
```

A success records an event with type `:ok`. A `failure(:card_declined)` records one with that type, written after the rollback of the case. An exception records nothing: it is a bug, and goes to your error tracker. Queries and subscribers never record.

Turn recording on or off for one command with `events :enabled` or `events :disabled`, which win over `config.events.recording`.

## Custom events

`emit` publishes a fact beyond the result of the command:

```ruby
class Payment::Charge < Lucid::Case::Command
  def call!
    payment.capture!
    emit(:credit_limit_reached, customer_id: payment.customer_id) if payment.customer.at_limit?
    success(payment: payment)
  end
end
```

Two events come out of one call: the Case event `payment.charge` (always) and the Custom event `credit_limit_reached` (only when the `if` holds). `:credit_limit_reached` and `"credit_limit_reached"` are the same event. `emit` in a query or a subscriber raises `EmitOutsideCommand`, and it does nothing when recording is off.

## Subscribers

A subscriber is a case of kind `:subscriber`. It declares what it reacts to with `subscribe` and receives the event:

```ruby
class Billing::OnEnrollmentApproved < Lucid::Case::Subscriber
  subscribe Enrollment::Approve

  def call!
    Billing::StartInvoice.call(enrollment: event.content[:enrollment])
    success
  end
end
```

A subscriber is transactional like a command (`transaction :disabled` works), accepts `step`, `catch`, `finally` and hooks, and never produces events of its own: the commands it calls produce theirs. It can be called directly in a test with `Billing::OnEnrollmentApproved.call(event: event)`.

`subscribe` takes a command class (Case event) or a name (Custom event), and can appear several times:

```ruby
class Dashboard::OnEnrollmentChange < Lucid::Case::Subscriber
  subscribe Enrollment::Approve
  subscribe Enrollment::Reject, on: :any
  subscribe :credit_limit_reached
  subscribe Provisioning::Run, step: :start
end
```

`on:` says which outcome you want: `:success` (default), `:failure`, `:any`, a failure type such as `:card_declined`, or an array of them. It does not apply to custom events. `subscribe` outside a subscriber raises `SubscribeOutsideSubscriber`; an invalid target, step or `on:` raises `InvalidSubscription`.

`subscribe` is a public class method, so it also works from outside, which is useful when you keep the wiring in one place:

```ruby
Rails.application.config.to_prepare do
  Billing::OnEnrollmentApproved.subscribe(Enrollment::Approve)
end
```

For a small reaction that does not deserve a class, subscribe a block with a name:

```ruby
Lucid::Case.subscribe(Enrollment::Approve, as: :guardian_mailer) do |event|
  GuardianMailer.approved(event.content[:enrollment]).deliver_later
end
```

`as:` is the identity of the subscriber and is required when deduplication is on or the subscription is `ordered`.

### Where subscribers load

Rails loads classes on demand in development and test. A subscriber nobody referenced yet would not be registered and the event would go out unnoticed. At boot, and on every reload, the gem clears the registry and loads the directories in `config.events.load_paths` (default `%w[app/models]`). A directory that does not exist raises `ArgumentError`. If your subscribers live elsewhere, point to them:

```ruby
config.events.load_paths = %w[app/subscribers]
```

## Steps

A subscriber can follow a step of a stepped command:

```ruby
subscribe Order::Place, step: :reserve_stock
```

The step event carries the content of the `continue`, `skip_to` or `success` that ended the step, and is only recorded when some subscriber asks for that step.

The rule is that **the event follows the data**. In a transactional case, if a later step fails, the transaction rolls back, the reservation is gone, and so is the event. In a case with `transaction :disabled`, each step commits on its own:

```ruby
class Provisioning::Run < Lucid::Case::Command
  transaction :disabled
  step(:start) { provisioning.update!(status: :running); continue }
  step(:configure_dns) { Dns::Configure.call(host: provisioning.host); success }
end
```

If `configure_dns` raises, the status `running` stays in the database, and so does the event of `start`, which is delivered. That is where step events are worth the most: following long pipelines.

## The event

Subscribers receive a `Lucid::Case::Event`: `id` (a UUID), `kind` (`:case`, `:step` or `:custom`), `name`, `source` (the class that produced it), `step`, `type`, `success?`, `input`, `content`, `context`, `occurred_at`, `to_h` and `Event.from_h`.

`input` holds the attributes of the case and `content` the content of the result (the keywords of `emit` in a custom event). Both go through `ActiveJob::Arguments`, like the arguments of a job: records become GlobalIDs and come back reloaded when the subscriber runs, so it sees the record as it is then, not a copy. `input` is passed through `filter_parameters` first, so a `password` is stored as `[FILTERED]`. `content` is not filtered: it is business data, and personal data in it is up to you.

Something that cannot be serialized (a lambda, a record that was not saved) raises `UnserializableEvent`. In a transactional case that rolls everything back. In a case with `transaction :disabled` the data is already written, so the exception rises and, with logging on, a line says the event was lost.

To send less, shape the content yourself. The event then carries no input:

```ruby
class Enrollment::Approve < Lucid::Case::Command
  event_payload { |result| { enrollment_id: result[:enrollment].id } }
end
```

## Delivery

With `config.events.store = :outbox` (the default) each event is a row in `lucid_case_events`, written in the command's transaction. After the commit a **relay** hands the row to the transport, which by default enqueues one `Lucid::Case::Events::DeliveryJob` per subscriber. A subscriber that fails is retried on its own (`config.events.delivery_attempts`, default 5) and the others are untouched. A subscriber that returns a `failure` counts as delivered.

If the process dies between the commit and the relay, the row stays pending. Schedule a sweep that delivers what was left behind and purges old rows:

```ruby
Lucid::Case::Events.relay_pending
```

Run it every minute with cron or your job backend's recurring tasks (solid_queue's `recurring.yml`, sidekiq-cron). It claims rows so two sweeps never take the same one, and raises `RelayFailed` with the ids after the whole batch when a transport failed, so the failure shows in your job backend.

`config.events.retention` (default `7.days`) says how long delivered rows are kept, and the sweep deletes older ones when `config.events.purge` is `:enabled`. Rows that were not delivered are never deleted. The outbox is not an audit trail: keep your own record if you need one.

With `store = :inline` there is no table: subscribers run in-process right after the commit. It is at-most-once, which is fine in tests and in apps that do not want the migration. If a subscriber raises, the others still run and the first error is raised afterwards.

### Delivery is at least once

A subscriber can receive the same event twice, and events are not ordered. Make subscribers idempotent using `event.id`:

```ruby
class Billing::OnEnrollmentApproved < Lucid::Case::Subscriber
  subscribe Enrollment::Approve

  def call!
    Invoice.find_or_create_by!(source_event_id: event.id) { |invoice| invoice.enrollment = event.content[:enrollment] }
    success
  end
end
```

Or let the gem skip repeated deliveries: `config.events.deduplication = :enabled` (needs the `:outbox` store, raises `ArgumentError` with `:inline`) records `(event id, subscriber)` in `lucid_case_deliveries`. In a transactional subscriber the mark is inside its transaction, so the effect in the database happens once. In a block or a subscriber without transaction the mark is written before the call and removed if it raises, so the retry runs again.

### Order

Subscribe with `ordered: true` to receive the events of a subscription in the order they were recorded, one at a time:

```ruby
subscribe Ledger::Post, ordered: true
```

If the second event fails, the third waits until the second passes. That is what ordering costs, so it is off by default and per subscription. See "Ordered delivery" below.

## Context

The subscriber runs in a job, without the request's `Current`. Capture what it needs when the event is recorded and restore it around each delivery:

```ruby
config.events.context = -> { { organization_id: Current.organization&.id } }
config.events.around_delivery = lambda do |context, &block|
  Current.set(organization_id: context[:organization_id], &block)
end
```

`context` must be serializable. The subscriber also sees it as `event.context`. With one schema per tenant, capture the schema in `context` and switch to it in `around_delivery`. The outbox then needs a table every tenant can see; `table_name` accepts a qualified name:

```ruby
config.events.table_name = "public.lucid_case_events"
```

## Logging

With logging on (see [Logging](logging.md)) each recorded event leaves a line. A case without a transaction that raises after recording events logs a `warn` listing the events that were kept and will be delivered. Failures that must not pass silently (a transport that failed, a delivery that gave up, an event already purged) log at `error`. Without logging the gem writes nothing, but `relay_pending` raises `RelayFailed` and a delivery job lets its last exception rise, so your job backend records it.

## Ordered delivery

An ordered subscription is delivered by `Lucid::Case::Events::OrderedDeliveryJob`, one per subscriber. It locks a cursor row (`lucid_case_cursors`) so only one job processes that subscriber at a time, takes the pending events of the subscription after the cursor, in recording order, and advances the cursor after each success. The first error stops the run and the job retries from the same event. The purge keeps events that an ordered subscriber has not processed yet.

## Transports

The transport is what the relay hands events to. See [Event transports](event-transports.md) to publish to SQS, RabbitMQ or anything else.
