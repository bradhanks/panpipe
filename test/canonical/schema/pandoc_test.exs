defmodule Canonical.Schema.PandocTest do
  use ExUnit.Case, async: true
  alias Canonical.Schema
  alias Canonical.Schema.{NodeSpec, Pandoc}

  test "schema/0 declares the expected top node and key nodes/marks" do
    schema = Pandoc.schema()
    assert schema.top_node == "doc"

    for type <- ~w(doc paragraph heading code_block bullet_list ordered_list list_item
                   table table_row table_cell table_header table_caption
                   definition_list def_term def_desc div line_block horizontal_rule
                   raw_block unsupported_block text image hard_break math footnote
                   raw_inline unsupported_inline) do
      assert {:ok, %NodeSpec{}} = Schema.node_spec(schema, type), "missing node #{type}"
    end

    for mark <-
          ~w(em strong code link strikethrough superscript subscript smallcaps underline span) do
      assert {:ok, _} = Schema.mark_spec(schema, mark), "missing mark #{mark}"
    end
  end

  test "paragraph allows all marks; code_block allows none" do
    schema = Pandoc.schema()
    assert {:ok, %NodeSpec{marks: :all}} = Schema.node_spec(schema, "paragraph")
    assert {:ok, %NodeSpec{marks: nil}} = Schema.node_spec(schema, "code_block")
  end

  test "heading carries a level attr default" do
    {:ok, spec} = Schema.node_spec(Pandoc.schema(), "heading")
    assert spec.attrs["level"] == %{default: 1}
  end
end
