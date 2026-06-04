defmodule Canonical.Schema.ValidatorTest do
  use ExUnit.Case, async: true
  alias Canonical.{Node, Mark}
  alias Canonical.Schema.{Pandoc, Validator}

  defp schema, do: Pandoc.schema()

  defp para(text, marks \\ []) do
    %Node{type: "paragraph", attrs: %{"id" => "p"}, content: [Node.text(text, marks)]}
  end

  test "valid doc passes" do
    doc = %Node{type: "doc", content: [para("hello")]}
    assert Validator.validate(doc, schema()) == :ok
  end

  test "unknown node type is rejected" do
    doc = %Node{type: "doc", content: [%Node{type: "bogus"}]}
    assert {:error, violations} = Validator.validate(doc, schema())
    assert Enum.any?(violations, &(&1.message =~ "unknown node type"))
  end

  test "content-expression violation is rejected" do
    # table_row may only contain table_cell/table_header, not a paragraph
    row = %Node{type: "table_row", attrs: %{"id" => "r"}, content: [para("x")]}
    assert {:error, violations} = Validator.validate(row, schema())
    assert Enum.any?(violations, &(&1.message =~ "content"))
  end

  test "disallowed mark on inline child is rejected" do
    # code_block allows no marks on its text children
    cb = %Node{
      type: "code_block",
      attrs: %{"id" => "c"},
      content: [Node.text("x", [Mark.new("em")])]
    }

    assert {:error, violations} = Validator.validate(cb, schema())
    assert Enum.any?(violations, &(&1.message =~ "mark"))
  end

  test "missing required attr is rejected" do
    # unsupported_block requires a "pandoc" attr (no default)
    node = %Node{type: "unsupported_block", attrs: %{"id" => "u"}}
    assert {:error, violations} = Validator.validate(node, schema())
    assert Enum.any?(violations, &(&1.message =~ "missing attr"))
  end
end
