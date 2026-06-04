defmodule Canonical.ExportTest do
  use ExUnit.Case, async: true

  defp counter_gen do
    {:ok, pid} = Agent.start_link(fn -> 0 end)

    fn ->
      n = Agent.get_and_update(pid, &{&1, &1 + 1})
      "id#{n}"
    end
  end

  defp import!(md, fmt \\ :markdown) do
    {:ok, doc, _} = Canonical.ingest(md, from: fmt, id_generator: counter_gen())
    doc |> Canonical.to_pm_json()
  end

  test "round-trips a rich document back to markdown" do
    doc = import!("# Title\n\nA para with *em*, **strong**, `code`, and [link](http://x).")
    assert {:ok, md} = Canonical.export(doc, to: :markdown)
    assert md =~ "# Title"
    assert md =~ "*em*"
    assert md =~ "**strong**"
    assert md =~ "`code`"
    assert md =~ "[link](http://x)"
  end

  test "exports lists, blockquote, and code blocks to HTML" do
    doc = import!("- a\n- b\n\n> quote\n\n```elixir\nIO.puts(:hi)\n```")
    assert {:ok, html} = Canonical.export(doc, to: :html)
    assert html =~ "<ul>"
    assert html =~ "<li>"
    assert html =~ "<blockquote>"
    assert html =~ "<pre"
    # pandoc may syntax-highlight, splitting tokens across spans, so match a token
    assert html =~ "puts"
  end

  test "exports a table without crashing and preserves cell text" do
    doc = import!("| A | B |\n|---|---|\n| 1 | 2 |")
    assert {:ok, md} = Canonical.export(doc, to: :markdown)
    assert md =~ "A"
    assert md =~ "1"
    assert md =~ "2"
  end

  test "exports a definition list" do
    doc = import!("Term\n:   a definition\n")
    assert {:ok, md} = Canonical.export(doc, to: :markdown)
    assert md =~ "Term"
    assert md =~ "definition"
  end

  test "round-trips raw HTML (escape node) through export" do
    doc = import!("<aside class=\"note\">hi</aside>", :html)
    assert {:ok, html} = Canonical.export(doc, to: :html)
    assert html =~ "hi"
  end
end
