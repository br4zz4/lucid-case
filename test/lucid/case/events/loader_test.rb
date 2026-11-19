require "test_helper"
require "tmpdir"
require "fileutils"
require "pathname"
require "zeitwerk"
require "lucid/case/railtie"

class EventsLoaderTest < Minitest::Test
  class FakeAutoloader
    attr_reader :dirs

    def initialize
      @dirs = []
    end

    def eager_load_dir(dir)
      @dirs << dir
    end
  end

  def loader = Lucid::Case::Events::Loader

  def registry = Lucid::Case::Events::Registry

  def setup
    @original = Lucid::Case.configuration
    Lucid::Case.reset_configuration!
    registry.clear!
    @root = Pathname.new(Dir.mktmpdir("lucid-loader"))
    @zeitwerk = nil
  end

  def teardown
    @zeitwerk&.unload
    registry.clear!
    %i[Enrollment Billing].each do |name|
      Object.send(:remove_const, name) if Object.const_defined?(name, false)
    end
    FileUtils.remove_entry(@root) if @root.exist?
    Lucid::Case.instance_variable_set(:@configuration, @original)
  end

  def configure_paths(*paths)
    Lucid::Case.configuration.events.load_paths = paths
  end

  def write_file(relative, content)
    path = @root.join(relative)
    FileUtils.mkdir_p(path.dirname)
    File.write(path, content)
  end

  def test_clears_the_registry
    # arrange
    target = build_case("Enrollment::Approve", parent: Lucid::Case::Command)
    build_case("Billing::OnApproved", parent: Lucid::Case::Subscriber) { subscribe target }
    configure_paths("app/models")
    FileUtils.mkdir_p(@root.join("app/models"))

    # act
    loader.prepare!(root: @root, autoloader: FakeAutoloader.new)

    # assert
    assert_equal [], registry.subscriptions
  end

  def test_eager_loads_each_load_path_in_order_as_absolute_strings
    # arrange
    configure_paths("app/models", "app/subscribers")
    FileUtils.mkdir_p(@root.join("app/models"))
    FileUtils.mkdir_p(@root.join("app/subscribers"))
    autoloader = FakeAutoloader.new

    # act
    loader.prepare!(root: @root, autoloader: autoloader)

    # assert
    assert_equal [@root.join("app/models").to_s, @root.join("app/subscribers").to_s], autoloader.dirs
    assert autoloader.dirs.all?(String)
  end

  def test_accepts_root_as_string
    # arrange
    configure_paths("app/models")
    FileUtils.mkdir_p(@root.join("app/models"))
    autoloader = FakeAutoloader.new

    # act
    loader.prepare!(root: @root.to_s, autoloader: autoloader)

    # assert
    assert_equal [@root.join("app/models").to_s], autoloader.dirs
  end

  def test_does_not_eager_load_dirs_when_eager_load_is_true
    # arrange
    configure_paths("app/models")
    FileUtils.mkdir_p(@root.join("app/models"))
    autoloader = FakeAutoloader.new
    target = build_case("Enrollment::Approve", parent: Lucid::Case::Command)
    build_case("Billing::OnApproved", parent: Lucid::Case::Subscriber) { subscribe target }

    # act
    loader.prepare!(root: @root, autoloader: autoloader, eager_load: true)

    # assert
    assert_equal [], autoloader.dirs
    assert_equal [], registry.subscriptions
  end

  def test_raises_for_missing_load_path
    # arrange
    configure_paths("app/models", "app/missing")
    FileUtils.mkdir_p(@root.join("app/models"))
    autoloader = FakeAutoloader.new

    # act
    error = assert_raises(ArgumentError) { loader.prepare!(root: @root, autoloader: autoloader) }

    # assert
    assert_includes error.message, "app/missing"
  end

  def test_raises_for_missing_load_path_even_when_eager_load_is_true
    # arrange
    configure_paths("app/missing")
    autoloader = FakeAutoloader.new

    # act
    error = assert_raises(ArgumentError) { loader.prepare!(root: @root, autoloader: autoloader, eager_load: true) }

    # assert
    assert_includes error.message, "app/missing"
  end

  def test_registers_subscribers_without_referencing_constants_and_survives_reload
    # arrange
    write_file "app/models/enrollment/approve.rb", <<~RUBY
      module Enrollment
        class Approve < Lucid::Case::Command
          def call! = success
        end
      end
    RUBY
    write_file "app/models/billing/on_approved.rb", <<~RUBY
      module Billing
        class OnApproved < Lucid::Case::Subscriber
          subscribe Enrollment::Approve
        end
      end
    RUBY
    configure_paths("app/models")
    @zeitwerk = Zeitwerk::Loader.new
    @zeitwerk.push_dir(@root.join("app/models").to_s)
    @zeitwerk.enable_reloading
    @zeitwerk.setup
    assert_equal [], registry.subscriptions

    # act
    loader.prepare!(root: @root, autoloader: @zeitwerk)

    # assert
    assert_equal 1, registry.subscriptions.size
    assert_equal "enrollment.approve", registry.subscriptions.first.target_name

    # act
    @zeitwerk.reload
    loader.prepare!(root: @root, autoloader: @zeitwerk)

    # assert
    assert_equal 1, registry.subscriptions.size
    assert_equal "enrollment.approve", registry.subscriptions.first.target_name
  end

  def test_railtie_registers_a_to_prepare_block
    # assert
    assert defined?(Lucid::Case::Railtie)
    assert_operator Lucid::Case::Railtie.config.to_prepare_blocks.size, :>=, 1
    assert defined?(Lucid::Case::Events::Loader)
  end
end
