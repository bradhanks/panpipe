defmodule Canonical.SchemaTest do
  use ExUnit.Case, async: true
  alias Canonical.Schema
  alias Canonical.Schema.{NodeSpec, MarkSpec}

  setup do
    schema = %Schema{
      top_node: "doc",
      nodes: %{
        "doc" => %NodeSpec{content: "block+"},
        "paragraph" => %NodeSpec{content: "inline*", group: "block", inline: false, marks: :all},
        "text" => %NodeSpec{text?: true, inline: true, group: "inline"}
      },
      marks: %{"em" => %MarkSpec{}}
    }

    {:ok, schema: schema}
  end

  test "node_spec/2 fetches specs", %{schema: schema} do
    assert {:ok, %NodeSpec{content: "block+"}} = Schema.node_spec(schema, "doc")
    assert :error = Schema.node_spec(schema, "nope")
  end

  test "groups/2 returns a node's groups", %{schema: schema} do
    assert Schema.groups(schema, "paragraph") == ["block"]
    assert Schema.groups(schema, "text") == ["inline"]
  end

  test "mark_allowed?/2 follows :all / list / nil", %{schema: _schema} do
    assert Schema.mark_allowed?(:all, "em")
    assert Schema.mark_allowed?(["em", "strong"], "em")
    refute Schema.mark_allowed?(["strong"], "em")
    refute Schema.mark_allowed?(nil, "em")
  end
end
