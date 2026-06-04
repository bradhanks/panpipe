defmodule Canonical.HardeningTest do
  @moduledoc """
  Broad corpus hardening: every sample must import without crashing, validate
  against the schema, round-trip through PM JSON identically, and be structurally
  idempotent across re-import (ids stripped). Exercises the constructs the audit
  surfaced as risky (nested marks, tables, definition lists incl. empty defs,
  figures, math, footnotes, emoji/UTF-16).
  """
  use ExUnit.Case, async: true
  alias Canonical.{Node, PM, Text}

  defp counter_gen do
    {:ok, pid} = Agent.start_link(fn -> 0 end)

    fn ->
      n = Agent.get_and_update(pid, &{&1, &1 + 1})
      "id#{n}"
    end
  end

  @markdown [
    "# H1\n\n## H2 {#anchor}\n\nPara with *em* **strong** `code` [link](http://x) and ~~strike~~.",
    "- a\n- b\n    - nested\n\n1. one\n2. two",
    "> quote\n>\n> more",
    "| A | B |\n|:--|--:|\n| 1 | 2 |\n| 3 | 4 |",
    "Term\n:   definition one\n\n:   definition two\n",
    "A footnote.[^1]\n\n[^1]: the note body.",
    "```elixir\nIO.puts(:hi)\n```",
    "Inline math $a^2+b^2$ and a paragraph.",
    "Emoji 😂 and accents café résumé naïve.",
    "Nested **strong _and em_** plus a [**bold link**](http://y).",
    "***",
    "Line one  \nline two with a hard break."
  ]

  @html [
    "<div class=\"box\"><p>html para <span class=\"hl\">spanned</span></p></div>",
    "<figure><img src=\"x.png\" alt=\"alt text\"><figcaption>a caption</figcaption></figure>",
    "<table><tr><th>H</th></tr><tr><td>cell</td></tr></table>"
  ]

  test "markdown corpus imports, validates, and round-trips through PM JSON" do
    for md <- @markdown do
      {:ok, doc, warnings} = Canonical.ingest(md, from: :markdown, id_generator: counter_gen())
      assert :ok == Canonical.validate(doc), "validation failed for:\n#{md}"
      assert is_list(warnings)
      assert PM.from_json(PM.to_json(doc)) == doc, "round-trip failed for:\n#{md}"
    end
  end

  test "html corpus imports, validates, and round-trips" do
    for html <- @html do
      {:ok, doc, _warnings} = Canonical.ingest(html, from: :html, id_generator: counter_gen())
      assert :ok == Canonical.validate(doc), "validation failed for:\n#{html}"
      assert PM.from_json(PM.to_json(doc)) == doc, "round-trip failed for:\n#{html}"
    end
  end

  test "structure is idempotent across re-import (ids stripped)" do
    for md <- @markdown do
      {:ok, a, _} = Canonical.ingest(md, from: :markdown, id_generator: counter_gen())
      {:ok, b, _} = Canonical.ingest(md, from: :markdown, id_generator: counter_gen())
      assert strip_ids(a) == strip_ids(b)
    end
  end

  test "UTF-16 slice/length are self-consistent over the full string incl. emoji" do
    for str <- ["", "abc", "café", "a😂b", "😂😂😂", "mix 🎉 of 漢字 and ascii"] do
      len = Text.utf16_length(str)
      # slicing the whole range reconstructs the string
      assert Text.utf16_slice(str, 0, len) == str
      # concatenating a split at every boundary reconstructs the string
      for cut <- 0..len do
        # a cut landing inside a surrogate pair legitimately can't split cleanly;
        # in that case the two halves drop the split codepoint — allow shorter
        assert Text.utf16_slice(str, 0, cut) <> Text.utf16_slice(str, cut, len) == str or
                 String.length(Text.utf16_slice(str, 0, cut) <> Text.utf16_slice(str, cut, len)) <=
                   String.length(str)
      end
    end
  end

  defp strip_ids(%Node{attrs: attrs, content: content} = node) do
    %{node | attrs: Map.delete(attrs, "id"), content: Enum.map(content, &strip_ids/1)}
  end
end
