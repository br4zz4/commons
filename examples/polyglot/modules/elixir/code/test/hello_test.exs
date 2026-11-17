defmodule HelloTest do
  use ExUnit.Case

  test "greet" do
    assert Hello.greet("world") == "hello world"
  end
end
