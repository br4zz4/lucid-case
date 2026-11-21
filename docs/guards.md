# Fail-fast guards

A guard is a predicate that ends the case with a typed failure before the body runs. Guards fail fast: they are declared in order, and the first one that holds ends the case with its failure.

```ruby
class ClassEnrollment::Create < Lucid::Case::Command
  attributes :student_id, :school_class_id

  fail_if :class_full?
  fail_if :already_enrolled?

  def call!
    success(enrollment: ClassEnrollment.create!(student: student, school_class: school_class))
  end

  private

  def student = @student ||= Child.find(student_id)
  def school_class = @school_class ||= SchoolClass.find(school_class_id)
  def class_full? = school_class.full?
  def already_enrolled? = student.class_enrollments.active.for_period(school_class.period).exists?
end

ClassEnrollment::Create.call(student_id: 1, school_class_id: 2)
  .on_failure(:class_full) { |result| flash[:alert] = result[:errors].first }
```

When `class_full?` is true the result is `failure(:class_full, errors: ["Turma está com capacidade máxima"])` and `call!` never runs. The failure type is the method name without the trailing `?`. `errors` is always an array with the failure message.

## When it runs

Guards run after the attribute validations (`validates`) and before `call!` or the steps:

1. `validates` fails: `failure(:invalid_attributes, errors:)`, no guard runs.
2. Guards, in declaration order. A parent class guard runs before a subclass guard. The first one that holds wins and the next ones are not called.
3. `call!` or the steps.

A guard runs inside the transaction (commands) or with writes blocked (queries), and inside `catch`. An exception raised by a predicate goes to `catch` like any other. A guard failure is a normal failure: the transaction rolls back, `after_failure` runs, `after_commit` does not, and the Case event records the failure type.

## The block form

For a one-line condition you can skip the method. The first argument is then the failure type, and the block runs with the case as `self`.

```ruby
fail_if(:class_full) { school_class.full? }
```

With a block the name must not end in `?` and `as:` is not accepted.

## Options

| Option | Meaning |
|---|---|
| `as: :duplicate` | Failure type for a method guard, instead of the method name. |
| `message: "Template em uso"` | A literal message, no I18n lookup. |
| `message: :"other.key"` | An I18n key. A missing key is a bug in the app, so it has no default. |
| `with: :provisioning` | Adds the value of that method of the case to the failure content. |
| `with: %i[resource event]` | Several methods. |

```ruby
fail_if :not_retryable?, with: :provisioning
```

On failure the content is `{ errors: [...], provisioning: provisioning }`. `with:` accepts any method of the case, public or private, an attribute or a reader. The methods are only called when the guard holds. `:errors` is reserved for the message and cannot be used.

## The failure message

The message is resolved when the guard holds, in the current locale, in this order:

1. `message:` as a String.
2. `message:` as a Symbol, read as an I18n key.
3. `<case name underscored, with dots for />.<type>`, for example `class_enrollment.create.class_full`.
4. `lucid_case.failures.<type>`, a message shared by every case.
5. `type.to_s.humanize`, for example `"Class full"`. The message is never empty.

```yaml
pt-BR:
  class_enrollment:
    create:
      class_full: "Turma está com capacidade máxima"
  lucid_case:
    failures:
      not_found: "Registro não encontrado"
```

An anonymous class has no name, so the lookup starts at `lucid_case.failures.<type>`.

## fail_with

For a check that only makes sense in the middle of the body, `fail_with` builds the same failure.

```ruby
def call!
  plan = calculate_plan
  return fail_with(:nothing_to_do, plan: plan) if plan.empty?

  success(plan: plan)
end
```

The content is `{ errors: [message], plan: plan }`. `fail_with(:x, message: "text")` uses a literal message. Passing `errors:` as content raises `ArgumentError`.

## Guard, validation or failure in the body

| Use | When |
|---|---|
| `validates` | The input is malformed: blank, wrong class. The failure is always `:invalid_attributes`. |
| `fail_if` | A business condition known before any effect, with a type of its own and a message. |
| `failure` in the body | The outcome depends on something that happened during the body (a `save` that failed, a transition that was refused). |

## Errors

| Error | When |
|---|---|
| `ArgumentError` at load | `fail_if` without a name, a block guard named with `?`, `as:` with a block, a `message:` that is not a String or Symbol, a `with:` that is not a Symbol or an array of Symbols or includes `:errors`. |
| `ArgumentError` at call | `fail_with` with `errors:` in the content. |
| `NoMethodError` at call | The predicate or a `with:` method does not exist. |

## Logging

With logging on, the guard that holds leaves a line like `guard :class_full? -> failure(:class_full) content=[:errors]`. For a block guard the name is the failure type.
