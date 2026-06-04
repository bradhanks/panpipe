defmodule Canonical.Import.Inline do
  @moduledoc """
  Flattens Pandoc's nested inline IR into ProseMirror's flat text-with-marks model.

  Descends carrying an accumulated mark set; emits text/atomic inline nodes;
  coalesces adjacent equal-mark text runs. Marks are kept in canonical order
  (Canonical.Mark.sort/1) at node-construction time.
  """
  alias Canonical.{Node, Mark}
  alias Canonical.Import.Attrs

  @doc "Flatten a list of panpipe inline IR nodes into canonical inline nodes."
  def flatten(inlines, opts) when is_list(inlines) do
    inlines |> Enum.flat_map(&node(&1, [], opts)) |> coalesce()
  end

  defp do_flatten(inlines, marks, opts), do: Enum.flat_map(inlines, &node(&1, marks, opts))

  # --- mark-producing wrappers ---
  defp node(%Panpipe.AST.Emph{children: c}, marks, opts),
    do: do_flatten(c, add(marks, "em"), opts)

  defp node(%Panpipe.AST.Strong{children: c}, marks, opts),
    do: do_flatten(c, add(marks, "strong"), opts)

  defp node(%Panpipe.AST.Strikeout{children: c}, marks, opts),
    do: do_flatten(c, add(marks, "strikethrough"), opts)

  defp node(%Panpipe.AST.Superscript{children: c}, marks, opts),
    do: do_flatten(c, add(marks, "superscript"), opts)

  defp node(%Panpipe.AST.Subscript{children: c}, marks, opts),
    do: do_flatten(c, add(marks, "subscript"), opts)

  defp node(%Panpipe.AST.SmallCaps{children: c}, marks, opts),
    do: do_flatten(c, add(marks, "smallcaps"), opts)

  defp node(%Panpipe.AST.Underline{children: c}, marks, opts),
    do: do_flatten(c, add(marks, "underline"), opts)

  defp node(%Panpipe.AST.Link{children: c, target: target, title: title}, marks, opts) do
    do_flatten(c, add(marks, "link", %{"href" => target, "title" => title}), opts)
  end

  defp node(%Panpipe.AST.Span{children: c, attr: attr}, marks, opts) do
    do_flatten(c, add(marks, "span", Attrs.to_map(attr)), opts)
  end

  # --- leaf text ---
  defp node(%Panpipe.AST.Str{string: ""}, _marks, _opts), do: []
  defp node(%Panpipe.AST.Str{string: s}, marks, _opts), do: [Node.text(s, marks)]
  defp node(%Panpipe.AST.Space{}, marks, _opts), do: [Node.text(" ", marks)]

  defp node(%Panpipe.AST.SoftBreak{}, marks, opts) do
    if Keyword.get(opts, :preserve_soft_breaks, false),
      do: [Node.text("\n", marks)],
      else: [Node.text(" ", marks)]
  end

  defp node(%Panpipe.AST.LineBreak{}, marks, _opts),
    do: [%Node{type: "hard_break", marks: Mark.sort(marks)}]

  defp node(%Panpipe.AST.Code{string: s}, marks, _opts), do: [Node.text(s, add(marks, "code"))]

  # --- atomic inline nodes ---
  defp node(%Panpipe.AST.Image{target: target, title: title, children: alt}, marks, opts) do
    [
      %Node{
        type: "image",
        attrs: %{"src" => target, "alt" => inline_text(alt, opts), "title" => title},
        marks: Mark.sort(marks)
      }
    ]
  end

  defp node(%Panpipe.AST.Math{type: type, string: s}, marks, _opts) do
    mode = if type == "DisplayMath", do: "display", else: "inline"
    [%Node{type: "math", attrs: %{"mode" => mode, "tex" => s}, marks: Mark.sort(marks)}]
  end

  defp node(%Panpipe.AST.RawInline{format: format, string: s}, marks, _opts) do
    [
      %Node{
        type: "raw_inline",
        attrs: %{"format" => format, "text" => s},
        marks: Mark.sort(marks)
      }
    ]
  end

  defp node(%Panpipe.AST.Note{children: blocks}, marks, opts) do
    [
      %Node{
        type: "footnote",
        content: Canonical.Import.Block.map_blocks(blocks, opts),
        marks: Mark.sort(marks)
      }
    ]
  end

  # --- unwrapped passthroughs ---
  defp node(%Panpipe.AST.Quoted{type: qt, children: c}, marks, opts) do
    {open, close} = if qt == "SingleQuote", do: {"‘", "’"}, else: {"“", "”"}
    [Node.text(open, marks)] ++ do_flatten(c, marks, opts) ++ [Node.text(close, marks)]
  end

  defp node(%Panpipe.AST.Cite{children: c}, marks, opts), do: do_flatten(c, marks, opts)

  # --- fallback ---
  defp node(other, marks, _opts) do
    [
      %Node{
        type: "unsupported_inline",
        attrs: %{"pandoc" => Panpipe.AST.Node.to_pandoc(other)},
        marks: Mark.sort(marks)
      }
    ]
  end

  # --- helpers ---
  # Accumulate a mark. ProseMirror permits only ONE mark of a given type per text
  # node, so when the same type is already present (nested Span/Link/etc.) we MERGE
  # attrs into it — inner (newer) wins on scalar conflicts, classes are unioned —
  # rather than dropping the inner attrs or emitting a duplicate mark.
  defp add(marks, type, attrs \\ %{}) do
    if Enum.any?(marks, &(&1.type == type)) do
      Enum.map(marks, fn
        %Mark{type: ^type} = m -> Mark.new(type, merge_attrs(m.attrs, attrs))
        m -> m
      end)
    else
      marks ++ [Mark.new(type, attrs)]
    end
  end

  defp merge_attrs(outer, inner) do
    Map.merge(outer, inner, fn
      "classes", l, r when is_list(l) and is_list(r) -> Enum.uniq(l ++ r)
      _key, _l, r -> r
    end)
  end

  defp inline_text(inlines, opts) do
    inlines
    |> flatten(opts)
    |> Enum.map(fn
      %Node{type: "text", text: t} -> t
      _ -> ""
    end)
    |> Enum.join()
  end

  defp coalesce(nodes) do
    nodes
    |> Enum.reject(&match?(%Node{type: "text", text: ""}, &1))
    |> Enum.reduce([], fn
      %Node{type: "text"} = node, [%Node{type: "text"} = prev | rest] ->
        if prev.marks == node.marks,
          do: [%{prev | text: prev.text <> node.text} | rest],
          else: [node, prev | rest]

      node, acc ->
        [node | acc]
    end)
    |> Enum.reverse()
  end
end
