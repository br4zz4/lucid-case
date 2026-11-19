require "test_helper"
require "rails/generators/test_case"
require "generators/lucid/case/install/install_generator"

class InstallGeneratorTest < Rails::Generators::TestCase
  tests Lucid::Case::Generators::InstallGenerator
  destination File.expand_path("../../tmp/generators", __dir__)
  setup :prepare_destination

  test "creates the initializer configuring Lucid::Case" do
    # arrange
    # act
    run_generator

    # assert
    assert_file "config/initializers/lucid_case.rb", /Lucid::Case\.configure/
  end

  test "initializer sets the transaction and cache defaults" do
    # arrange
    # act
    run_generator

    # assert
    assert_file "config/initializers/lucid_case.rb" do |content|
      assert_match(/config\.transaction = :enabled/, content)
      assert_match(/config\.cache = :disabled/, content)
      assert_match(/config\.cache_duration = 5\.minutes/, content)
    end
  end

  test "initializer documents cache_scope and cache_store as comments" do
    # arrange
    # act
    run_generator

    # assert
    assert_file "config/initializers/lucid_case.rb" do |content|
      assert_match(/^\s*# config\.cache_scope = /, content)
      assert_match(/^\s*# config\.cache_store = /, content)
    end
  end
end
