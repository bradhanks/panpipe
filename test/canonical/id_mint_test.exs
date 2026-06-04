defmodule Canonical.IdMintTest do
  use ExUnit.Case, async: true
  alias Canonical.{Node, Id}

  # Deterministic generator for tests: id0, id1, ...
  defp counter_gen do
    {:ok, pid} = Agent.start_link(fn -> 0 end)

    fn ->
      n = Agent.get_and_update(pid, &{&1, &1 + 1})
      "id#{n}"
    end
  end

  test "mints ids on every non-text node, skipping text nodes" do
    tree = %Node{type: "doc", content: [%Node{type: "paragraph", content: [Node.text("x", [])]}]}
    {minted, warnings} = Id.mint(tree, id_generator: counter_gen())

    assert warnings == []
    assert minted.attrs["id"] != nil
    [para] = minted.content
    assert para.attrs["id"] != nil
    [text] = para.content
    refute Map.has_key?(text.attrs, "id")
  end

  test "preserves an existing non-empty id" do
    tree = %Node{type: "doc", attrs: %{"id" => "root"}, content: []}
    {minted, _} = Id.mint(tree, id_generator: counter_gen())
    assert minted.attrs["id"] == "root"
  end

  test "de-dupes colliding preserved ids and warns" do
    tree = %Node{
      type: "doc",
      content: [
        %Node{type: "paragraph", attrs: %{"id" => "dup"}, content: []},
        %Node{type: "paragraph", attrs: %{"id" => "dup"}, content: []}
      ]
    }

    {minted, warnings} = Id.mint(tree, id_generator: counter_gen())
    [a, b] = minted.content
    assert a.attrs["id"] == "dup"
    assert b.attrs["id"] != "dup"
    assert Enum.any?(warnings, &match?({:duplicate_id, "dup"}, &1))
  end
end
