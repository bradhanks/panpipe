defmodule Canonical.Export do
  @moduledoc """
  Renders a canonical ProseMirror-shaped doc map back out to any Pandoc output
  format (the inverse of `Canonical.Import`).

  Strategy: rebuild panpipe AST structs from the canonical map (un-flattening
  text+marks back into nested Pandoc inlines), then hand them to Pandoc as JSON.
  Escape nodes round-trip via their stashed Pandoc JSON. Table fidelity is basic
  (single body, default column spec); everything else is faithful.
  """
  alias Panpipe.AST, as: P

  @doc """
  Export a canonical doc map to a Pandoc format. `opts` must include `:to`
  (e.g. `to: :html`, `to: :markdown`); other opts pass through to Pandoc.
  Returns `{:ok, output_string}` or `{:error, reason}`.
  """
  def to_format(%{"type" => "doc"} = doc, opts) do
    blocks = doc |> content() |> Enum.map(&block/1)

    json =
      %Panpipe.Document{children: blocks}
      |> Panpipe.Document.to_pandoc()
      |> Jason.encode!()

    case Panpipe.pandoc(json, Keyword.put(opts, :from, :json)) do
      {:ok, out} -> {:ok, out}
      {:error, _} = error -> error
    end
  end

  # ── blocks ──────────────────────────────────────────────────────────────
  defp block(%{"type" => "paragraph"} = n), do: %P.Para{children: inlines(n)}

  defp block(%{"type" => "heading"} = n),
    do: %P.Header{level: attrs(n)["level"] || 1, attr: attr(attrs(n)), children: inlines(n)}

  defp block(%{"type" => "blockquote"} = n), do: %P.BlockQuote{children: blocks(n)}

  defp block(%{"type" => "code_block"} = n),
    do: %P.CodeBlock{string: text_content(n), attr: attr(attrs(n))}

  defp block(%{"type" => "bullet_list"} = n),
    do: %P.BulletList{children: Enum.map(content(n), &list_element/1)}

  defp block(%{"type" => "ordered_list"} = n) do
    a = attrs(n)

    la = %P.ListAttributes{
      start: a["start"] || 1,
      number_style: a["style"] || "Decimal",
      number_delimiter: a["delimiter"] || "Period"
    }

    %P.OrderedList{list_attributes: la, children: Enum.map(content(n), &list_element/1)}
  end

  defp block(%{"type" => "horizontal_rule"}), do: %P.HorizontalRule{}
  defp block(%{"type" => "div"} = n), do: %P.Div{attr: attr(attrs(n)), children: blocks(n)}

  defp block(%{"type" => "line_block"} = n),
    do: %P.LineBlock{children: Enum.map(content(n), &inlines/1)}

  defp block(%{"type" => "definition_list"} = n),
    do: %P.DefinitionList{children: definition_items(content(n))}

  defp block(%{"type" => "table"} = n), do: table(n)

  defp block(%{"type" => "raw_block"} = n),
    do: %P.RawBlock{format: attrs(n)["format"], string: attrs(n)["text"]}

  defp block(%{"type" => "unsupported_block"} = n),
    do: Panpipe.Pandoc.AST.Node.to_panpipe(attrs(n)["pandoc"])

  # Fallback: wrap unknown block content as a Div so nothing is lost.
  defp block(n), do: %P.Div{attr: %P.Attr{}, children: blocks(n)}

  defp list_element(%{"type" => "list_item"} = n), do: %P.ListElement{children: blocks(n)}
  defp list_element(n), do: %P.ListElement{children: blocks(n)}

  # Regroup [def_term, def_desc, def_desc, def_term, ...] back into Pandoc pairs.
  defp definition_items(nodes) do
    nodes
    |> Enum.reduce([], fn
      %{"type" => "def_term"} = t, acc ->
        [[inlines(t), []] | acc]

      %{"type" => "def_desc"} = d, [[term, defs] | rest] ->
        [[term, defs ++ [blocks(d)]] | rest]

      _other, acc ->
        acc
    end)
    |> Enum.reverse()
  end

  defp table(n) do
    rows = content(n)

    caption_blocks =
      rows
      |> Enum.filter(&(&1["type"] == "table_caption"))
      |> Enum.flat_map(&content/1)
      |> Enum.map(&block/1)

    body_rows = Enum.filter(rows, &(&1["type"] == "table_row"))
    {head_rows, data_rows} = Enum.split_with(body_rows, &all_header?/1)
    ncols = body_rows |> Enum.map(&length(content(&1))) |> Enum.max(fn -> 0 end)

    col_spec =
      for _ <- 1..max(ncols, 1),
          do: %P.ColSpec{alignment: "AlignDefault", col_width: "ColWidthDefault"}

    %P.Table{
      attr: attr(attrs(n)),
      caption: %P.Caption{short_caption: nil, blocks: caption_blocks},
      col_spec: col_spec,
      table_head: %P.TableHead{rows: Enum.map(head_rows, &table_row/1)},
      table_bodies: [
        %P.TableBody{
          row_head_columns: 0,
          intermediate_head_rows: [],
          intermediate_body_rows: Enum.map(data_rows, &table_row/1)
        }
      ],
      table_foot: %P.TableFoot{rows: []}
    }
  end

  defp all_header?(row), do: row |> content() |> Enum.all?(&(&1["type"] == "table_header"))

  defp table_row(row), do: %P.Row{cells: Enum.map(content(row), &table_cell/1)}

  defp table_cell(c) do
    a = attrs(c)

    %P.Cell{
      blocks: blocks(c),
      alignment: alignment(a["align"]),
      row_span: a["rowspan"] || 1,
      col_span: a["colspan"] || 1
    }
  end

  defp alignment("left"), do: "AlignLeft"
  defp alignment("right"), do: "AlignRight"
  defp alignment("center"), do: "AlignCenter"
  defp alignment(_), do: "AlignDefault"

  # ── inlines ─────────────────────────────────────────────────────────────
  defp inlines(node), do: node |> content() |> Enum.flat_map(&inline/1)

  defp inline(%{"type" => "text", "text" => t} = n), do: [wrap_marks(t, n["marks"] || [])]

  defp inline(%{"type" => "image"} = n) do
    a = attrs(n)

    [
      %P.Image{
        children: [%P.Str{string: a["alt"] || ""}],
        target: a["src"] || "",
        title: a["title"] || "",
        attr: %P.Attr{}
      }
    ]
  end

  defp inline(%{"type" => "hard_break"}), do: [%P.LineBreak{}]

  defp inline(%{"type" => "math"} = n) do
    a = attrs(n)
    type = if a["mode"] == "display", do: "DisplayMath", else: "InlineMath"
    [%P.Math{type: type, string: a["tex"] || ""}]
  end

  defp inline(%{"type" => "raw_inline"} = n),
    do: [%P.RawInline{format: attrs(n)["format"], string: attrs(n)["text"]}]

  defp inline(%{"type" => "footnote"} = n), do: [%P.Note{children: blocks(n)}]

  defp inline(%{"type" => "unsupported_inline"} = n),
    do: [Panpipe.Pandoc.AST.Node.to_panpipe(attrs(n)["pandoc"])]

  defp inline(_), do: []

  # Rebuild nested Pandoc inlines from a flat text + mark set.
  defp wrap_marks(text, marks) do
    types = Enum.map(marks, & &1["type"])

    base =
      if "code" in types, do: %P.Code{string: text, attr: %P.Attr{}}, else: %P.Str{string: text}

    Enum.reduce(marks, base, &wrap_mark/2)
  end

  defp wrap_mark(%{"type" => "code"}, acc), do: acc
  defp wrap_mark(%{"type" => "em"}, acc), do: %P.Emph{children: [acc]}
  defp wrap_mark(%{"type" => "strong"}, acc), do: %P.Strong{children: [acc]}
  defp wrap_mark(%{"type" => "underline"}, acc), do: %P.Underline{children: [acc]}
  defp wrap_mark(%{"type" => "strikethrough"}, acc), do: %P.Strikeout{children: [acc]}
  defp wrap_mark(%{"type" => "superscript"}, acc), do: %P.Superscript{children: [acc]}
  defp wrap_mark(%{"type" => "subscript"}, acc), do: %P.Subscript{children: [acc]}
  defp wrap_mark(%{"type" => "smallcaps"}, acc), do: %P.SmallCaps{children: [acc]}

  defp wrap_mark(%{"type" => "link"} = m, acc),
    do: %P.Link{children: [acc], target: attrs(m)["href"] || "", title: attrs(m)["title"] || ""}

  defp wrap_mark(%{"type" => "span"} = m, acc), do: %P.Span{children: [acc], attr: attr(attrs(m))}
  defp wrap_mark(_, acc), do: acc

  # ── helpers ─────────────────────────────────────────────────────────────
  defp content(%{"content" => c}) when is_list(c), do: c
  defp content(_), do: []

  defp blocks(node), do: node |> content() |> Enum.map(&block/1)

  defp attrs(%{"attrs" => a}) when is_map(a), do: a
  defp attrs(_), do: %{}

  defp text_content(node) do
    node
    |> content()
    |> Enum.map(fn
      %{"text" => t} -> t
      _ -> ""
    end)
    |> Enum.join()
  end

  defp attr(a) do
    %P.Attr{
      identifier: a["source_id"] || "",
      classes: a["classes"] || [],
      key_value_pairs: a["attrs"] || %{}
    }
  end
end
