# Getting started

Add the gem, run the generator, and write a case.

```ruby
gem 'lucid-case', github: 'br4zz4/lucid-case', tag: 'v0.1.0'
```

```sh
bundle install
bin/rails g lucid:case:install
```

The generator creates `config/initializers/lucid_case.rb` with every option and its default. You can leave it alone until you need caching or logging. See [Configuration](configuration.md).

## A command

```ruby
class Posts::Publish < Lucid::Case::Command
  attributes :post
  validates :post, kind: Post

  def call!
    return failure(:already_published, post: post) if post.published?

    post.update!(published_at: Time.current)
    success(post: post)
  end
end

result = Posts::Publish.call(post: post)
result.success?
result.type
result[:post]
```

Pass the inputs as keywords or as a hash. `call!` has to return `success(...)` or `failure(...)`, otherwise the call raises `Lucid::Case::Error::UnexpectedResult`. The command runs in a transaction, so a failure undoes whatever it wrote. See [Commands](commands.md).

## A query

```ruby
class Posts::Count < Lucid::Case::Query
  attributes :author

  def call!
    success(total: Post.where(author: author).count)
  end
end

Posts::Count.call(author: author)[:total]
```

A query only reads, and it can be cached. See [Queries](queries.md).

## A test

```ruby
class PostsPublishTest < ActiveSupport::TestCase
  test "fails when already published" do
    post = Post.create!(title: "Hi", published_at: Time.current)

    result = Posts::Publish.call(post: post)

    assert result.failure?
    assert_equal :already_published, result.type
  end
end
```

More in [Testing](testing.md).
