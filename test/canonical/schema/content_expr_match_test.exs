defmodule Canonical.Schema.ContentExprMatchTest do
  use ExUnit.Case, async: true
  alias Canonical.Schema
  alias Canonical.Schema.{NodeSpec, ContentExpr}

  setup do
    schema = %Schema{
      nodes: %{
        "paragraph" => %NodeSpec{group: "block"},
        "heading" => %NodeSpec{group: "block"},
        "text" => %NodeSpec{group: "inline", text?: true},
        "table_cell" => %NodeSpec{},
        "table_header" => %NodeSpec{}
      }
    }

    {:ok, schema: schema}
  end

  test "matches by group name", %{schema: schema} do
    expr = ContentExpr.parse("block+")
    assert ContentExpr.matches?(expr, ["paragraph", "heading"], schema)
    refute ContentExpr.matches?(expr, [], schema)
    refute ContentExpr.matches?(expr, ["text"], schema)
  end

  test "matches alternation under +", %{schema: schema} do
    expr = ContentExpr.parse("(table_cell | table_header)+")
    assert ContentExpr.matches?(expr, ["table_header", "table_cell", "table_cell"], schema)
    refute ContentExpr.matches?(expr, ["table_cell", "paragraph"], schema)
  end

  test "nil expr matches only empty content", %{schema: schema} do
    assert ContentExpr.matches?(nil, [], schema)
    refute ContentExpr.matches?(nil, ["text"], schema)
  end

  test "star matches zero", %{schema: schema} do
    assert ContentExpr.matches?(ContentExpr.parse("inline*"), [], schema)
    assert ContentExpr.matches?(ContentExpr.parse("inline*"), ["text", "text"], schema)
  end
end
