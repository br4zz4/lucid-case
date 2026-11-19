# Migrating from u-case

The method names are close, so most of the work is mechanical.

| u-case | Lucid::Case |
|---|---|
| `class X < Micro::Case` that writes | `class X < Lucid::Case::Command` |
| `class X < Micro::Case` that only computes | `class X < Lucid::Case::Query` |
| `attribute :a, default: 1` | `attributes :a, default: 1` (or `attribute :a, default: 1`) |
| `Success(result: { a: 1 })` | `success(a: 1)` |
| `Failure(:type, result: { a: 1 })` | `failure(:type, a: 1)` |
| `Failure(result: { a: 1 })` | `failure(a: 1)`, type `:error` |
| `transaction do ... end` in `call!` | gone, commands are transactional |
| `rescue X => e; Failure(...)` | `catch(X) { \|ctx\| failure(:type, error: ctx.error) }` |
| `perform_later` inside `call!` | `after_commit { \|result\| ... }` |
| `Micro::Case::Result` in specs | `Lucid::Case::Result` |
| hand-rolled caching | `Query` with `cache duration:` |

`attributes`, `validates :params, kind: Hash`, `result[:a]`, `result.type`, `result.success?`, `result.data`, `on_success` and `on_failure(:type)` stay as they are, so controllers keep working.

## Order of work

Replace the superclass with `Command` or `Query`. Rewrite `Success` and `Failure` as lowercase `success` and `failure`, which take keywords instead of `result:`. Delete manual `transaction do` blocks, and add `transaction :disabled` where a transaction is wrong: external I/O, batches, a case that saves its own failure. Turn the `rescue` blocks that end in a failure into `catch`. Move `perform_later` and notifications into `after_commit` so they only fire after a successful commit. If a query raises `ActiveRecord::ReadOnlyError` in your tests, it writes, so make it a command.

## What behaves differently

Commands roll back on `failure`, not only on exceptions. `after_commit` hooks run after the outermost transaction commits, where code in `call!` used to run before it. `success` and `failure` are private instance methods. A `call!` that returns something that is not a result raises `UnexpectedResult`.

## Before and after

```ruby
class Student::Create < Micro::Case
  attributes :params
  validates :params, kind: Hash

  def call!
    ActiveRecord::Base.transaction do
      student = Student.new(params)
      if student.save
        StudentMailer.welcome(student).deliver_later
        Success(result: { student: student })
      else
        Failure(:invalid, result: { errors: student.errors })
      end
    end
  rescue ActiveRecord::RecordNotUnique => e
    Failure(:duplicated, result: { error: e })
  end
end
```

```ruby
class Student::Create < Lucid::Case::Command
  attributes :params
  validates :params, kind: Hash

  after_commit { |result| StudentMailer.welcome(result[:student]).deliver_later }

  catch(ActiveRecord::RecordNotUnique) { |ctx| failure(:duplicated, error: ctx.error) }

  def call!
    student = Student.new(params)
    return failure(:invalid, errors: student.errors) unless student.save

    success(student: student)
  end
end
```
