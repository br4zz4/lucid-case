$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "lucid/case"
require "active_job"
require "logger"
require "stringio"
require "minitest/autorun"

GlobalID.app = "lucid-case-test"
ActiveJob::Base.queue_adapter = :test

ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")
ActiveRecord::Base.include GlobalID::Identification
ActiveRecord::Schema.verbose = false
ActiveRecord::Schema.define do
  create_table :users, force: true do |t|
    t.string :name
  end

  create_table :orders, force: true do |t|
    t.string :status
  end
end

class User < ActiveRecord::Base; end
class Order < ActiveRecord::Base; end

module CaseHelpers
  def build_case(name = "AnonymousCase", parent: Lucid::Case, &block)
    klass = Class.new(parent)
    klass.define_singleton_method(:name) { name }
    klass.class_eval(&block) if block
    klass
  end
end

class Minitest::Test
  include CaseHelpers
end

class EventsTest < Minitest::Test
  Error = Lucid::Case::Error

  attr_reader :events, :log

  def setup
    @original = Lucid::Case.configuration
    Lucid::Case.reset_configuration!
    Lucid::Case::Events::Registry.clear!
    @events = []
    @log = StringIO.new
    Lucid::Case.configuration.logger = Logger.new(@log)
    with_events
    User.delete_all
    Order.delete_all
    Thread.current[:lucid_test_tenant] = nil
  end

  def teardown
    Lucid::Case::Events::Registry.clear!
    Lucid::Case.instance_variable_set(:@configuration, @original)
    User.delete_all
    Order.delete_all
    Thread.current[:lucid_test_tenant] = nil
  end

  def with_events(store: :inline, recording: :enabled)
    Lucid::Case.configuration.events.store = store
    Lucid::Case.configuration.events.recording = recording
  end

  def spy(target, as: :spy, **options)
    Lucid::Case.subscribe(target, as: as, **options) { |event| @events << event }
  end

  def build_command(name = "Enrollment::Approve", &block)
    build_case(name, parent: Lucid::Case::Command, &block)
  end

  def build_subscriber(name, &block)
    build_case(name, parent: Lucid::Case::Subscriber, &block)
  end

  def event_log_lines
    log.string.lines.select { |line| line.include?("event") }
  end
end
