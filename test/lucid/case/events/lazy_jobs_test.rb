require "test_helper"
require "open3"
require "rbconfig"

class LazyJobsTest < Minitest::Test
  LIB = File.expand_path("../../../../lib", __dir__)

  def run_clean_ruby(script)
    Open3.capture3(RbConfig.ruby, "-I#{LIB}", "-e", script)
  end

  def test_requiring_lucid_case_does_not_load_active_job_base
    # arrange
    script = <<~RUBY
      require "active_job"
      require "lucid/case"
      checks = [
        ActiveJob.autoload?(:Base),
        Lucid::Case::Events.autoload?(:DeliveryJob),
        Lucid::Case::Events.autoload?(:OrderedDeliveryJob)
      ]
      puts checks.map { |check| check.nil? ? "nil" : "set" }.join(",")
    RUBY

    # act
    stdout, stderr, status = run_clean_ruby(script)

    # assert
    assert status.success?, stderr
    assert_equal "set,set,set", stdout.strip
  end

  def test_delivery_job_resolves_lazily_and_inherits_from_active_job_base
    # arrange
    # act
    job = Lucid::Case::Events::DeliveryJob

    # assert
    assert_operator job, :<, ::ActiveJob::Base
  end

  def test_ordered_delivery_job_resolves_lazily_and_inherits_from_active_job_base
    # arrange
    # act
    job = Lucid::Case::Events::OrderedDeliveryJob

    # assert
    assert_operator job, :<, ::ActiveJob::Base
  end
end
