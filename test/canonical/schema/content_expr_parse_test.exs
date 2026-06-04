defmodule Canonical.Schema.ContentExprParseTest do
  use ExUnit.Case, async: true
  alias Canonical.Schema.ContentExpr, as: CE

  test "parses empty as nil" do
    assert CE.parse("") == nil
  end

  test "parses a bare name" do
    assert CE.parse("block") == {:name, "block"}
  end

  test "parses quantifiers" do
    assert CE.parse("block+") == {:plus, {:name, "block"}}
    assert CE.parse("inline*") == {:star, {:name, "inline"}}
    assert CE.parse("table_caption?") == {:opt, {:name, "table_caption"}}
  end

  test "parses a sequence" do
    assert CE.parse("def_term def_desc+") ==
             {:seq, [{:name, "def_term"}, {:plus, {:name, "def_desc"}}]}
  end

  test "parses alternation with parens and quantifier" do
    assert CE.parse("(table_cell | table_header)+") ==
             {:plus, {:or, [{:name, "table_cell"}, {:name, "table_header"}]}}
  end

  test "parses a grouped sequence repeated" do
    assert CE.parse("(def_term def_desc+)+") ==
             {:plus, {:seq, [{:name, "def_term"}, {:plus, {:name, "def_desc"}}]}}
  end
end
