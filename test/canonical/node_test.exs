defmodule Canonical.NodeTest do
  use ExUnit.Case, async: true
  alias Canonical.{Node, Mark}

  test "text/2 builds a text node with sorted marks" do
    node = Node.text("hi", [Mark.new("strong"), Mark.new("em")])
    assert node.type == "text"
    assert node.text == "hi"
    # em ranks before strong in the canonical order
    assert Enum.map(node.marks, & &1.type) == ["em", "strong"]
  end

  test "text?/1 distinguishes text nodes" do
    assert Node.text?(Node.text("x", []))
    refute Node.text?(%Node{type: "paragraph"})
  end

  test "Mark.sort orders by canonical rank, then name" do
    marks = [Mark.new("link"), Mark.new("code"), Mark.new("em")]
    assert Enum.map(Mark.sort(marks), & &1.type) == ["em", "code", "link"]
  end
end
