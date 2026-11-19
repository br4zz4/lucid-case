require "test_helper"

class HooksTest < Minitest::Test
  def setup
    User.delete_all
    Lucid::Case.reset_configuration!
  end

  def teardown
    Lucid::Case.reset_configuration!
    User.delete_all
  end

  def hooked(outcome)
    build_case("Hooked", parent: Lucid::Case::Command) do
      attributes :log

      after_success { log << [:success, User.connection.transaction_open?] }
      after_failure { log << [:failure, User.connection.transaction_open?] }
      after_commit { log << [:commit, User.connection.transaction_open?] }

      define_method(:call!) do
        log << [:body, User.connection.transaction_open?]
        outcome == :success ? success : failure(:x)
      end
    end
  end

  def test_after_success_runs_inside_transaction_before_commit
    # arrange
    log = []
    klass = hooked(:success)

    # act
    klass.call(log: log)

    # assert
    assert_equal %i[body success commit], log.map(&:first)
    assert_equal [true, true, false], log.map(&:last)
  end

  def test_after_commit_waits_for_outer_transaction
    # arrange
    log = []
    klass = hooked(:success)
    seen_inside = nil

    # act
    ActiveRecord::Base.transaction do
      klass.call(log: log)
      log << [:outer_end, true]
      seen_inside = log.map(&:first)
    end

    # assert
    assert_equal %i[body success outer_end], seen_inside
    assert_equal %i[body success outer_end commit], log.map(&:first)
    refute log.last.last
  end

  def test_after_commit_discarded_when_outer_rolls_back
    # arrange
    log = []
    klass = hooked(:success)

    # act
    ActiveRecord::Base.transaction do
      klass.call(log: log)
      raise ActiveRecord::Rollback
    end

    # assert
    assert_equal %i[body success], log.map(&:first)
  end

  def test_after_commit_discarded_when_outer_raises
    # arrange
    log = []
    klass = hooked(:success)

    # act
    assert_raises(RuntimeError) do
      ActiveRecord::Base.transaction do
        klass.call(log: log)
        raise "outer boom"
      end
    end

    # assert
    refute_includes log.map(&:first), :commit
  end

  def test_failure_runs_only_after_failure
    # arrange
    log = []
    klass = hooked(:failure)

    # act
    ActiveRecord::Base.transaction { klass.call(log: log) }

    # assert
    assert_equal %i[body failure], log.map(&:first)
  end

  def test_failure_without_outer_transaction_runs_only_after_failure
    # arrange
    log = []
    klass = hooked(:failure)

    # act
    klass.call(log: log)

    # assert
    assert_equal %i[body failure], log.map(&:first)
  end

  def test_hooks_receive_result
    # arrange
    received = []
    klass = build_case("Hooked", parent: Lucid::Case::Command) do
      after_success { |result| received << result }
      def call! = success(id: 7)
    end

    # act
    result = klass.call

    # assert
    assert_equal [result.type], received.map(&:type)
    assert_equal 7, received.first[:id]
  end

  def symbol_hooked(outcome)
    build_case("Hooked", parent: Lucid::Case::Command) do
      attributes :log

      after_success :on_success
      after_failure :on_failure
      after_commit :on_commit

      define_method(:call!) do
        log << :body
        outcome == :success ? success : failure(:x)
      end
      define_method(:on_success) { |result| log << [:success, result.type] }
      define_method(:on_failure) { |result| log << [:failure, result.type] }
      define_method(:on_commit) { |result| log << [:commit, result.type] }
    end
  end

  def test_symbol_hooks_on_success
    # arrange
    log = []

    # act
    symbol_hooked(:success).call(log: log)

    # assert
    assert_equal [:body, [:success, :ok], [:commit, :ok]], log
  end

  def test_symbol_hooks_on_failure
    # arrange
    log = []

    # act
    symbol_hooked(:failure).call(log: log)

    # assert
    assert_equal [:body, [:failure, :x]], log
  end

  def test_multiple_hooks_run_in_declaration_order
    # arrange
    log = []
    klass = build_case("Hooked", parent: Lucid::Case::Command) do
      attributes :log

      after_success { log << 1 }
      after_success { log << 2 }

      def call! = success
    end

    # act
    klass.call(log: log)

    # assert
    assert_equal [1, 2], log
  end

  def test_transaction_disabled_runs_hooks_after_body
    # arrange
    log = []
    klass = build_case("Hooked", parent: Lucid::Case::Command) do
      attributes :log

      transaction :disabled
      after_success { log << [:success, User.connection.transaction_open?] }
      after_commit { log << [:commit, User.connection.transaction_open?] }

      define_method(:call!) do
        log << [:body, User.connection.transaction_open?]
        success
      end
    end

    # act
    klass.call(log: log)

    # assert
    assert_equal [[:body, false], [:success, false], [:commit, false]], log
  end

  def test_transaction_disabled_failure_runs_after_failure
    # arrange
    log = []
    klass = build_case("Hooked", parent: Lucid::Case::Command) do
      attributes :log

      transaction :disabled
      after_success { log << :success }
      after_failure { log << :failure }
      after_commit { log << :commit }

      define_method(:call!) do
        log << :body
        failure(:x)
      end
    end

    # act
    klass.call(log: log)

    # assert
    assert_equal %i[body failure], log
  end

  def test_query_with_hooks_raises
    # act / assert
    %i[after_success after_failure after_commit].each do |macro|
      assert_raises(Lucid::Case::Error::SideEffectInQuery) do
        build_case(parent: Lucid::Case::Query) { public_send(macro) { nil } }
      end
    end
  end

  def test_hook_without_method_or_block
    # act / assert
    assert_raises(ArgumentError) { build_case(parent: Lucid::Case::Command) { after_success } }
  end
end
