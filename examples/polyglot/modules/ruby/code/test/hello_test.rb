require "minitest/autorun"
require "hello"

class HelloTest < Minitest::Test
  def test_greet
    assert_equal "hello world", Hello.greet("world")
  end
end
