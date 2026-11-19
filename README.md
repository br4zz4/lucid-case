# Lucid::Case

Use cases for Rails. You write the logic as a `call!` or as a list of steps, and the call comes back as a result you can branch on.

```ruby
class Users::Create < Lucid::Case
  kind :command
  logging :enabled, values: true

  attributes :params
  validates :params, kind: Hash

  after_commit { |result| WelcomeMailer.with(user: result[:user]).welcome.deliver_later }

  catch(ActiveRecord::RecordNotUnique) { |context| failure(:email_taken, error: context.error.message) }

  def call!
    user = User.new(params)
    return failure(:invalid, errors: user.errors) unless user.save

    success(user: user)
  end
end

Users::Create.call(params: { email: "ana@example.com" })
  .on_success { |result| redirect_to result[:user] }
  .on_failure(:email_taken) { |result| render :new }
  .on_failure(:invalid) { |result| render :new, locals: { errors: result[:errors] } }
```

A command runs inside a transaction. If it returns a `failure`, or raises, everything it wrote is rolled back. `after_commit` waits for the commit, so the mailer never goes out for a user that was rolled back. `catch` turns an exception into a failure you can name.

With `logging :enabled` each call leaves this in the log:

```
[Lucid::Case] Users::Create called input={params: {email: "ana@example.com"}}
[Lucid::Case] Users::Create success content={user: #<User id: 7>} in 4.2ms
```

Without `values: true` only the names are logged (`input=[:params]`), and values are always filtered through your app's `filter_parameters`. Inside a case you can also write your own lines with `logger.info(...)`. See [Logging](docs/logging.md).

## Steps

When a case is a sequence of things that can stop half way, write it as steps. Each step says whether to go on, jump, or finish.

```ruby
class Provisioning::Run < Lucid::Case
  kind :command
  transaction :disabled

  attributes :provisioning

  step(:already_done) { provisioning.succeeded? ? success(provisioning: provisioning) : continue }

  step(:start) do
    provisioning.update!(status: :running)
    continue
  end

  step(:configure_dns) do
    Dns::Configure.call(host: provisioning.host)
    continue(host: provisioning.host)
  end

  step(:finish) do
    provisioning.update!(status: :succeeded)
    success(provisioning: provisioning)
  end

  catch(StandardError) do |context|
    provisioning.update!(status: :failed, last_error: context.error.message)
    failure(:provisioning_failed, provisioning: provisioning, error: context.error.message)
  end

  finally(:release_lock) { ProvisioningLock.release(provisioning) }
end

Provisioning::Run.call(provisioning: provisioning)
  .on_failure(:provisioning_failed) { |result| notify(result[:error]) }
```

`continue` goes to the next step and can carry content, `skip_to(:step)` jumps ahead, `success` and `failure` end the case. A case has `call!` or steps, not both. `finally` is cleanup that always runs at the end, like Java's: here the lock is released after a success, a failure or an exception. The transaction is turned off on purpose: the DNS call is slow, and the `failed` status written in `catch` has to survive. See [Steps](docs/steps.md) and [Catch and finally](docs/catch.md).

## Query

A query only reads. Any write raises `ActiveRecord::ReadOnlyError`, which is what makes it safe to cache.

```ruby
class Dashboard::Evolution < Lucid::Case
  kind :query
  cache duration: 5.minutes

  attributes :period

  def call!
    success(points: Contract.where(period: period).group(:status).count)
  end
end

result = Dashboard::Evolution.call(period: period)
result[:points]
result.cached_at

Dashboard::Evolution.fresh.call(period: period)
Dashboard::Evolution.stale(period: period)
Dashboard::Evolution.stale(:period)
Dashboard::Evolution.stale
```

The second call with the same period comes from the cache and runs nothing. `fresh` recomputes and stores again. `stale(period: period)` drops that one entry, `stale(:period)` drops every entry that depends on `period`, and `stale` with no arguments drops them all. See [Queries](docs/queries.md) and [Cache](docs/cache.md).

## Another way to write them

`Lucid::Case::Command` and `Lucid::Case::Query` are the same classes with the kind already set:

```ruby
class Users::Create < Lucid::Case::Command
  ...
end

class Dashboard::Evolution < Lucid::Case::Query
  ...
end
```

## Installation

```ruby
gem 'lucid-case', github: 'br4zz4/lucid-case', tag: 'v0.1.0'
```

Ruby 3.2 or newer, Rails 7.2 or newer. Then:

```sh
bundle install
bin/rails g lucid:case:install
```

The generator creates `config/initializers/lucid_case.rb` with every option and its default.

## Command or query

Use a command when the case writes something. It gets a transaction by default, and it can have `after_success`, `after_failure` and `after_commit`. Turn the transaction off with `transaction :disabled` when the case talks to something outside the database, loops over independent items, or has to save its own failure.

Use a query when the case only reads or computes. It never gets a transaction or hooks (declaring one raises `SideEffectInQuery`), and it is the only kind that accepts `cache`. Declaring `cache` on a command raises `CacheOnCommand`.

`attributes`, `validates`, `step` and `catch` work the same in both.

## Guides

- [Getting started](docs/getting-started.md)
- [Commands](docs/commands.md)
- [Queries](docs/queries.md)
- [Steps](docs/steps.md)
- [Catch and finally](docs/catch.md)
- [Cache](docs/cache.md)
- [Logging](docs/logging.md)
- [Result](docs/result.md)
- [Configuration](docs/configuration.md)
- [Errors](docs/errors.md)
- [Testing](docs/testing.md)
- [Migrating from u-case](docs/migrating-from-u-case.md)
- [Roadmap](docs/roadmap.md)

## License

MIT. See [LICENSE](LICENSE).
