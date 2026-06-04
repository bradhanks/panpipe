defmodule Canonical.Import.AttrsTest do
  use ExUnit.Case, async: true
  alias Canonical.Import.Attrs

  test "empty Attr yields empty map" do
    assert Attrs.to_map(%Panpipe.AST.Attr{}) == %{}
  end

  test "maps identifier (as source_id), classes, key-value pairs" do
    attr = %Panpipe.AST.Attr{identifier: "x", classes: ["a", "b"], key_value_pairs: %{"k" => "v"}}

    assert Attrs.to_map(attr) ==
             %{"source_id" => "x", "classes" => ["a", "b"], "attrs" => %{"k" => "v"}}
  end

  test "add_class/2 appends without duplicating" do
    assert Attrs.add_class(%{}, "figure") == %{"classes" => ["figure"]}
    assert Attrs.add_class(%{"classes" => ["figure"]}, "figure") == %{"classes" => ["figure"]}
    assert Attrs.add_class(%{"classes" => ["a"]}, "figure") == %{"classes" => ["a", "figure"]}
  end
end
