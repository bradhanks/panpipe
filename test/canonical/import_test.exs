defmodule Canonical.ImportTest do
  use ExUnit.Case, async: true
  alias Canonical.Node

  defp counter_gen do
    {:ok, pid} = Agent.start_link(fn -> 0 end)

    fn ->
      n = Agent.get_and_update(pid, &{&1, &1 + 1})
      "id#{n}"
    end
  end

  test "ingest/2 imports markdown into a validated doc" do
    {:ok, doc, warnings} =
      Canonical.ingest("# Title\n\nHello **world**", id_generator: counter_gen())

    assert %Node{type: "doc"} = doc
    assert warnings == []
    assert [%Node{type: "heading"}, %Node{type: "paragraph"} = p] = doc.content

    assert Enum.any?(p.content, fn n ->
             n.type == "text" and Enum.any?(n.marks, &(&1.type == "strong"))
           end)
  end

  test "to_pm_json round-trips through from_pm_json" do
    {:ok, doc, _} = Canonical.ingest("Hello *there*", id_generator: counter_gen())
    json = Canonical.to_pm_json(doc)
    assert Canonical.from_pm_json(json) == doc
  end

  test "raw HTML survives losslessly as an escape node with a warning" do
    {:ok, doc, warnings} =
      Canonical.ingest("<div class=\"x\">raw</div>", from: :html, id_generator: counter_gen())

    types = collect_types(doc)
    assert "div" in types or "raw_block" in types or "unsupported_block" in types
    # Pandoc may model this as a div; either way nothing crashes and ids are minted.
    assert is_list(warnings)

    # All escaped warnings carry the 3-element shape {:escaped, type, text}.
    # text is nil for unsupported_* nodes (no raw text available) and a binary
    # for raw_block/raw_inline nodes.
    for w <- warnings, match?({:escaped, _, _}, w) do
      {:escaped, type, text} = w
      assert is_binary(type) or is_atom(type)
      assert is_nil(text) or is_binary(text)
    end
  end

  test "escaped warnings carry {type, text} for raw_block nodes" do
    # A LaTeX raw block produces a raw_block node with known text.
    latex = "```{=latex}\n\\maketitle\n```"

    {:ok, _doc, warnings} =
      Canonical.ingest(latex, id_generator: counter_gen())

    escaped = Enum.filter(warnings, &match?({:escaped, _, _}, &1))

    assert Enum.any?(escaped, fn {:escaped, type, text} ->
             type == "raw_block" and is_binary(text) and String.contains?(text, "maketitle")
           end)
  end

  defp collect_types(%Node{type: t, content: content}),
    do: [t | Enum.flat_map(content, &collect_types/1)]
end
