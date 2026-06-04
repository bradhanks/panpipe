defmodule Canonical.Import.Block do
  @moduledoc "Maps Pandoc block IR into canonical block nodes."
  alias Canonical.Node
  alias Canonical.Import.{Inline, Attrs}

  def map_blocks(blocks, opts) when is_list(blocks), do: Enum.flat_map(blocks, &map(&1, opts))

  defp map(%Panpipe.AST.Para{children: c}, opts),
    do: [%Node{type: "paragraph", content: Inline.flatten(c, opts)}]

  defp map(%Panpipe.AST.Plain{children: c}, opts),
    do: [%Node{type: "paragraph", content: Inline.flatten(c, opts)}]

  defp map(%Panpipe.AST.Header{level: level, attr: attr, children: c}, opts) do
    attrs = Map.put(Attrs.to_map(attr), "level", level)
    [%Node{type: "heading", attrs: attrs, content: Inline.flatten(c, opts)}]
  end

  defp map(%Panpipe.AST.BlockQuote{children: c}, opts),
    do: [%Node{type: "blockquote", content: map_blocks(c, opts)}]

  defp map(%Panpipe.AST.CodeBlock{string: s, attr: attr}, _opts) do
    base = Attrs.to_map(attr)

    attrs =
      case attr.classes do
        [lang | _] -> Map.put(base, "language", lang)
        _ -> base
      end

    content = if s == "", do: [], else: [%Node{type: "text", text: s}]
    [%Node{type: "code_block", attrs: attrs, content: content}]
  end

  defp map(%Panpipe.AST.RawBlock{format: format, string: s}, _opts),
    do: [%Node{type: "raw_block", attrs: %{"format" => format, "text" => s}}]

  defp map(%Panpipe.AST.HorizontalRule{}, _opts), do: [%Node{type: "horizontal_rule"}]

  defp map(%Panpipe.AST.BulletList{children: items}, opts),
    do: [%Node{type: "bullet_list", content: Enum.map(items, &list_item(&1, opts))}]

  defp map(%Panpipe.AST.OrderedList{list_attributes: la, children: items}, opts),
    do: [
      %Node{
        type: "ordered_list",
        attrs: list_attrs(la),
        content: Enum.map(items, &list_item(&1, opts))
      }
    ]

  defp map(%Panpipe.AST.LineBlock{children: lines}, opts) do
    paras =
      Enum.map(lines, fn line -> %Node{type: "paragraph", content: Inline.flatten(line, opts)} end)

    [%Node{type: "line_block", content: paras}]
  end

  defp map(%Panpipe.AST.Div{attr: attr, children: c}, opts),
    do: [%Node{type: "div", attrs: Attrs.to_map(attr), content: map_blocks(c, opts)}]

  defp map(%Panpipe.AST.DefinitionList{children: items}, opts) do
    content =
      Enum.flat_map(items, fn [term, definitions] ->
        [
          %Node{type: "def_term", content: Inline.flatten(term, opts)}
          | def_descs(definitions, opts)
        ]
      end)

    [%Node{type: "definition_list", content: content}]
  end

  defp map(%Panpipe.AST.Table{} = t, opts) do
    caption = table_caption(t.caption, opts)
    head = Enum.map(t.table_head.rows, &table_row(&1, "table_header", opts))

    body =
      Enum.flat_map(t.table_bodies, fn b ->
        Enum.map(b.intermediate_head_rows, &table_row(&1, "table_header", opts)) ++
          Enum.map(b.intermediate_body_rows, &body_row(&1, b.row_head_columns, opts))
      end)

    foot = Enum.map(t.table_foot.rows, &table_row(&1, "table_cell", opts))
    attrs = Map.put(Attrs.to_map(t.attr), "colspec", colspec(t.col_spec))
    [%Node{type: "table", attrs: attrs, content: caption ++ head ++ body ++ foot}]
  end

  defp map(%Panpipe.AST.Figure{caption: caption, attr: attr, children: blocks}, opts) do
    attrs = Attrs.add_class(Attrs.to_map(attr), "figure")

    caption_blocks =
      case caption do
        %Panpipe.AST.Caption{blocks: []} -> []
        %Panpipe.AST.Caption{blocks: cap} -> map_blocks(cap, opts)
        _ -> []
      end

    [%Node{type: "div", attrs: attrs, content: map_blocks(blocks, opts) ++ caption_blocks}]
  end

  defp map(other, _opts),
    do: [
      %Node{type: "unsupported_block", attrs: %{"pandoc" => Panpipe.AST.Node.to_pandoc(other)}}
    ]

  # --- helpers ---

  # A term may legitimately carry zero definitions (Pandoc `[term, []]`), and an
  # individual definition may map to zero blocks. `def_desc` requires `block+`, so
  # substitute an empty paragraph to keep the doc schema-valid (and lossless about
  # the term itself) rather than failing the whole import.
  defp def_descs([], _opts), do: [%Node{type: "def_desc", content: [empty_paragraph()]}]

  defp def_descs(definitions, opts) do
    Enum.map(definitions, fn blocks ->
      %Node{type: "def_desc", content: blocks_or_empty(map_blocks(blocks, opts))}
    end)
  end

  defp blocks_or_empty([]), do: [empty_paragraph()]
  defp blocks_or_empty(blocks), do: blocks

  defp empty_paragraph, do: %Node{type: "paragraph", content: []}

  # The first `row_head_columns` cells of each body row are stub (row-header) cells
  # in Pandoc's model; type them as table_header, the rest as table_cell.
  defp body_row(%Panpipe.AST.Row{cells: cells}, head_cols, opts)
       when is_integer(head_cols) and head_cols > 0 do
    {stub, data} = Enum.split(cells, head_cols)

    content =
      Enum.map(stub, &table_cell(&1, "table_header", opts)) ++
        Enum.map(data, &table_cell(&1, "table_cell", opts))

    %Node{type: "table_row", content: content}
  end

  defp body_row(row, _head_cols, opts), do: table_row(row, "table_cell", opts)

  defp list_item(%Panpipe.AST.ListElement{children: blocks}, opts),
    do: %Node{type: "list_item", content: map_blocks(blocks, opts)}

  defp list_attrs(%Panpipe.AST.ListAttributes{
         start: start,
         number_style: style,
         number_delimiter: delim
       }),
       do: %{"start" => start, "style" => style, "delimiter" => delim}

  defp list_attrs(_), do: %{"start" => 1, "style" => "Decimal", "delimiter" => "Period"}

  defp table_caption(%Panpipe.AST.Caption{blocks: []}, _opts), do: []

  defp table_caption(%Panpipe.AST.Caption{blocks: blocks}, opts),
    do: [%Node{type: "table_caption", content: map_blocks(blocks, opts)}]

  defp table_caption(_, _opts), do: []

  defp table_row(%Panpipe.AST.Row{cells: cells}, cell_type, opts),
    do: %Node{type: "table_row", content: Enum.map(cells, &table_cell(&1, cell_type, opts))}

  defp table_cell(
         %Panpipe.AST.Cell{blocks: blocks, alignment: a, row_span: rs, col_span: cs},
         cell_type,
         opts
       ) do
    %Node{
      type: cell_type,
      attrs: %{"align" => align(a), "rowspan" => rs, "colspan" => cs},
      content: map_blocks(blocks, opts)
    }
  end

  defp align("AlignLeft"), do: "left"
  defp align("AlignRight"), do: "right"
  defp align("AlignCenter"), do: "center"
  defp align(_), do: "default"

  defp colspec(specs) when is_list(specs),
    do:
      Enum.map(specs, fn %Panpipe.AST.ColSpec{alignment: a, col_width: w} ->
        %{"align" => align(a), "width" => w}
      end)

  defp colspec(_), do: []
end
