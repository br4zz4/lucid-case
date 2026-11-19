require "test_helper"

class KindsTest < Minitest::Test
  Error = Lucid::Case::Error

  def test_command_kind
    # arrange
    klass = build_case(parent: Lucid::Case::Command)

    # assert
    assert klass.command?
    refute klass.query?
    assert_equal :command, klass.kind
  end

  def test_query_kind
    # arrange
    klass = build_case(parent: Lucid::Case::Query)

    # assert
    assert klass.query?
    refute klass.command?
    assert_equal :query, klass.kind
  end

  def test_default_kind_is_command
    # arrange
    klass = build_case

    # assert
    assert klass.command?
    assert_equal :command, klass.kind
  end

  def test_kind_query_declared_directly_matches_inheriting
    # arrange
    declared = build_case { kind :query }
    inherited = build_case(parent: Lucid::Case::Query)

    # assert
    assert_equal inherited.query?, declared.query?
    assert_equal inherited.command?, declared.command?
    assert_equal inherited.kind, declared.kind
  end

  def test_declared_query_blocks_writes_like_inherited
    # arrange
    klass = build_case do
      kind :query
      def call! = success(user: User.create!(name: "Ana"))
    end

    # act / assert
    assert_raises(ActiveRecord::ReadOnlyError) { klass.call }
  end

  def test_unknown_kind
    # act / assert
    assert_raises(Error::InvalidKind) { build_case { kind :other } }
  end

  def test_query_redeclared_as_command
    # act / assert
    assert_raises(Error::InvalidKind) { build_case(parent: Lucid::Case::Query) { kind :command } }
  end

  def test_command_redeclared_as_query
    # act / assert
    assert_raises(Error::InvalidKind) { build_case(parent: Lucid::Case::Command) { kind :query } }
  end

  def test_declared_query_then_command
    # act / assert
    assert_raises(Error::InvalidKind) do
      build_case do
        kind :query
        kind :command
      end
    end
  end

  def test_declared_command_then_query
    # act / assert
    assert_raises(Error::InvalidKind) do
      build_case do
        kind :command
        kind :query
      end
    end
  end

  def test_redeclaring_same_value
    # arrange
    query = build_case(parent: Lucid::Case::Query) { kind :query }
    command = build_case(parent: Lucid::Case::Command) { kind :command }

    # assert
    assert query.query?
    assert command.command?
  end

  def test_query_after_transaction
    # act / assert
    assert_raises(Error::SideEffectInQuery) do
      build_case do
        transaction :enabled
        kind :query
      end
    end
  end

  def test_query_after_after_success
    # act / assert
    assert_raises(Error::SideEffectInQuery) do
      build_case do
        after_success { nil }
        kind :query
      end
    end
  end

  def test_query_after_after_failure
    # act / assert
    assert_raises(Error::SideEffectInQuery) do
      build_case do
        after_failure { nil }
        kind :query
      end
    end
  end

  def test_query_after_after_commit
    # act / assert
    assert_raises(Error::SideEffectInQuery) do
      build_case do
        after_commit { nil }
        kind :query
      end
    end
  end

  def test_subclasses_inherit_kind
    # arrange
    parent = build_case(parent: Lucid::Case::Query)
    child = build_case(parent: parent)
    command_parent = build_case(parent: Lucid::Case::Command)
    command_child = build_case(parent: command_parent)

    # assert
    assert child.query?
    assert_equal :query, child.kind
    assert command_child.command?
  end

  def test_subclass_cannot_change_inherited_kind
    # arrange
    parent = build_case(parent: Lucid::Case::Query)

    # act / assert
    assert_raises(Error::InvalidKind) { build_case(parent: parent) { kind :command } }
  end
end
