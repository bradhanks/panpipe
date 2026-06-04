defmodule Canonical.PropertiesTest do
  use ExUnit.Case, async: true
  alias Canonical.{Node, PM}

  defp counter_gen do
    {:ok, pid} = Agent.start_link(fn -> 0 end)

    fn ->
      n = Agent.get_and_update(pid, &{&1, &1 + 1})
      "id#{n}"
    end
  end

  @samples [
    "# Heading\n\nA paragraph with *em*, **strong**, `code`, and [a link](http://x).",
    "- one\n- two\n\n1. a\n2. b",
    "> quote\n>\n> more",
    "Term\n: Definition one\n: Definition two",
    "| A | B |\n|---|--:|\n| 1 | 2 |",
    "Here is a footnote.[^1]\n\n[^1]: The note.",
    "```elixir\nIO.puts(:hi)\n```"
  ]

  test "every sample imports, validates, and round-trips through PM JSON" do
    for md <- @samples do
      {:ok, doc, _warnings} = Canonical.ingest(md, id_generator: counter_gen())
      assert :ok == Canonical.validate(doc), "validation failed for: #{md}"
      assert PM.from_json(PM.to_json(doc)) == doc, "round-trip failed for: #{md}"
    end
  end

  test "structure is idempotent across re-import (ids stripped)" do
    md = "# H\n\nText with **bold**."
    {:ok, a, _} = Canonical.ingest(md, id_generator: counter_gen())
    {:ok, b, _} = Canonical.ingest(md, id_generator: counter_gen())
    assert strip_ids(a) == strip_ids(b)
  end

  test "unknown raw inline is preserved losslessly with a warning" do
    {:ok, doc, warnings} =
      Canonical.ingest("a <span>x</span> b", from: :html, id_generator: counter_gen())

    assert :ok == Canonical.validate(doc)
    assert is_list(warnings)
  end

  defp strip_ids(%Node{attrs: attrs, content: content} = node) do
    %{node | attrs: Map.delete(attrs, "id"), content: Enum.map(content, &strip_ids/1)}
  end
end
