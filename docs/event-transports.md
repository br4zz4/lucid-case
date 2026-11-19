# Event transports

Events are stored in the outbox in the command's transaction. A **transport** takes it from there. The default, `:active_job`, enqueues one job per subscriber. To send events to a broker, write a transport: any object that responds to `publish(event)`.

```ruby
Lucid::Case.configure do |config|
  config.events.transport = SqsTransport.new(queue_url: ENV.fetch("EVENTS_QUEUE_URL"))
end
```

## Why the broker is not the source of truth

There is no commit that covers your database and SQS or RabbitMQ at once. Publishing inside the transaction creates a phantom event when it rolls back. Publishing after the commit loses the event if the process dies in between. The outbox solves both: the row is written with the data, and the relay publishes after the commit. If publishing fails, the row stays pending and the sweep (`Lucid::Case::Events.relay_pending`) delivers it later. The broker is only a destination, and delivery is at least once.

## The contract

- `publish(event)` receives a `Lucid::Case::Event`. If it raises, the row stays pending and is retried by the sweep. It must not swallow errors.
- It may be called more than once for the same event. Use `event.id` to deduplicate on the other side.
- `event.to_h` is JSON friendly and `Lucid::Case::Event.from_h(hash)` rebuilds an equal event on the consumer, so a worker reading the queue gets the same object subscribers get.
- The gem calls it in-process after the commit and in the sweep. Keep it fast, or enqueue and return.

Records in `input` and `content` are serialized as GlobalIDs inside the event; the consumer needs the same app to reload them. For a different app, send ids in `event_payload` instead.

## SQS

```ruby
class SqsTransport
  def initialize(queue_url:, client: Aws::SQS::Client.new)
    @queue_url = queue_url
    @client = client
  end

  def publish(event)
    @client.send_message(
      queue_url: @queue_url,
      message_body: JSON.generate(event.to_h),
      message_attributes: { "event_name" => { data_type: "String", string_value: event.name } },
      message_deduplication_id: event.id,
      message_group_id: event.name
    )
  end
end
```

`message_deduplication_id` and `message_group_id` are for FIFO queues; drop them on a standard queue. The consumer does `Lucid::Case::Event.from_h(JSON.parse(body))`.

## RabbitMQ

```ruby
class RabbitTransport
  def initialize(connection:, exchange: "lucid_case")
    @channel = connection.create_channel
    @exchange = @channel.topic(exchange, durable: true)
  end

  def publish(event)
    @exchange.publish(JSON.generate(event.to_h), routing_key: event.name, message_id: event.id, persistent: true)
  end
end
```

The routing key is the event name, so a queue can bind to `enrollment.*`.

## Several destinations

A transport can fan out: call the default one for in-app subscribers and a broker for other systems.

```ruby
class FanOut
  def initialize(*transports) = @transports = transports
  def publish(event) = @transports.each { |transport| transport.publish(event) }
end

config.events.transport = FanOut.new(Lucid::Case::Events::Transports::ActiveJob, SqsTransport.new(queue_url: url))
```

If one of them raises, the row stays pending and the sweep calls all of them again, so every transport must tolerate repeats.
