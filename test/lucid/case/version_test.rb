require "test_helper"

class VersionTest < Minitest::Test
  def test_version_is_0_3_0
    # arrange
    # act
    version = Lucid::Case::VERSION

    # assert
    assert_equal "0.3.0", version
  end

  def test_changelog_has_a_0_2_0_section_describing_events
    # arrange
    path = File.expand_path("../../../CHANGELOG.md", __dir__)

    # act
    section = File.read(path)[/^## 0\.2\.0\b.*?(?=^## |\z)/m]

    # assert
    refute_nil section
    assert_match(/event/i, section)
  end
end
