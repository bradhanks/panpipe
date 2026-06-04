defmodule Canonical.TextTest do
  use ExUnit.Case, async: true
  alias Canonical.Text

  @doc_node %{
    "type" => "doc",
    "content" => [
      %{
        "type" => "paragraph",
        "attrs" => %{"id" => "p"},
        "content" => [
          %{"type" => "text", "text" => "Hi "},
          %{"type" => "text", "text" => "world", "marks" => [%{"type" => "strong"}]}
        ]
      }
    ]
  }

  test "flatten_text/1 concatenates descendant text from a node map" do
    assert Text.flatten_text(@doc_node) == "Hi world"
  end

  test "utf16_length/1 counts UTF-16 code units (surrogate pairs = 2)" do
    assert Text.utf16_length("abc") == 3
    # 😂 (U+1F602) is one codepoint but TWO UTF-16 code units
    assert Text.utf16_length("a😂b") == 4
  end

  test "utf16_slice/3 uses (from, to) end-offsets and is surrogate-safe" do
    assert Text.utf16_slice("hello", 0, 2) == "he"
    assert Text.utf16_slice("hello", 2, 5) == "llo"
    # slice that lands on the emoji's two code units returns the whole emoji
    assert Text.utf16_slice("a😂b", 1, 3) == "😂"
    # clamps past the end; empty when from==to
    assert Text.utf16_slice("hi", 1, 99) == "i"
    assert Text.utf16_slice("hi", 1, 1) == ""
  end

  test "utf16_slice/3 returns \"\" when a slice splits a surrogate pair" do
    # offsets 2..3 land between the two UTF-16 code units of 😂 → invalid UTF-16
    assert Text.utf16_slice("a😂b", 2, 3) == ""
  end
end
