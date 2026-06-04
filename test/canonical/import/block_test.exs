defmodule Canonical.Import.BlockTest do
  use ExUnit.Case, async: true
  alias Canonical.Node
  alias Canonical.Import.Block

  defp s(str), do: %Panpipe.AST.Str{string: str}
  defp para(str), do: %Panpipe.AST.Para{children: [s(str)]}

  test "Para/Plain map to paragraph" do
    assert [%Node{type: "paragraph", content: [%Node{text: "hi"}]}] =
             Block.map_blocks([para("hi")], [])

    assert [%Node{type: "paragraph"}] =
             Block.map_blocks([%Panpipe.AST.Plain{children: [s("x")]}], [])
  end

  test "Header maps to heading with level and the Pandoc id preserved as source_id" do
    h = %Panpipe.AST.Header{
      level: 2,
      attr: %Panpipe.AST.Attr{identifier: "intro"},
      children: [s("Intro")]
    }

    assert [%Node{type: "heading", attrs: attrs}] = Block.map_blocks([h], [])
    assert attrs["level"] == 2
    # The Pandoc identifier is preserved as source_id (cross-ref anchor); the
    # stable node "id" is minted later by Canonical.Id, not in block mapping.
    assert attrs["source_id"] == "intro"
    refute Map.has_key?(attrs, "id")
  end

  test "CodeBlock maps to code_block with language and text content" do
    cb = %Panpipe.AST.CodeBlock{string: "puts :hi", attr: %Panpipe.AST.Attr{classes: ["elixir"]}}

    assert [
             %Node{
               type: "code_block",
               attrs: attrs,
               content: [%Node{type: "text", text: "puts :hi"}]
             }
           ] =
             Block.map_blocks([cb], [])

    assert attrs["language"] == "elixir"
  end

  test "BulletList maps items to list_item containing blocks" do
    item = %Panpipe.AST.ListElement{children: [para("a")]}

    assert [
             %Node{
               type: "bullet_list",
               content: [%Node{type: "list_item", content: [%Node{type: "paragraph"}]}]
             }
           ] = Block.map_blocks([%Panpipe.AST.BulletList{children: [item]}], [])
  end

  test "OrderedList carries list attributes" do
    item = %Panpipe.AST.ListElement{children: [para("a")]}

    la = %Panpipe.AST.ListAttributes{
      start: 3,
      number_style: "Decimal",
      number_delimiter: "Period"
    }

    ol = %Panpipe.AST.OrderedList{list_attributes: la, children: [item]}
    assert [%Node{type: "ordered_list", attrs: attrs}] = Block.map_blocks([ol], [])
    assert attrs == %{"start" => 3, "style" => "Decimal", "delimiter" => "Period"}
  end

  test "RawBlock maps to raw_block escape node" do
    rb = %Panpipe.AST.RawBlock{format: "html", string: "<x>"}

    assert [%Node{type: "raw_block", attrs: %{"format" => "html", "text" => "<x>"}}] =
             Block.map_blocks([rb], [])
  end

  test "DefinitionList maps term then defs" do
    dl = %Panpipe.AST.DefinitionList{children: [[[s("Term")], [[para("Def")]]]]}
    assert [%Node{type: "definition_list", content: content}] = Block.map_blocks([dl], [])
    assert [%Node{type: "def_term"}, %Node{type: "def_desc"}] = content
  end

  test "Table maps caption + header/body rows with cell alignment" do
    cell = %Panpipe.AST.Cell{
      blocks: [para("c")],
      alignment: "AlignRight",
      row_span: 1,
      col_span: 1
    }

    row = %Panpipe.AST.Row{cells: [cell]}
    head = %Panpipe.AST.TableHead{rows: [row]}
    body = %Panpipe.AST.TableBody{intermediate_head_rows: [], intermediate_body_rows: [row]}
    cap = %Panpipe.AST.Caption{blocks: [para("cap")]}

    table = %Panpipe.AST.Table{
      col_spec: [%Panpipe.AST.ColSpec{alignment: "AlignRight", col_width: "ColWidthDefault"}],
      table_head: head,
      table_bodies: [body],
      table_foot: %Panpipe.AST.TableFoot{rows: []},
      caption: cap,
      attr: %Panpipe.AST.Attr{}
    }

    assert [%Node{type: "table", content: content}] = Block.map_blocks([table], [])

    assert [
             %Node{type: "table_caption"},
             %Node{type: "table_row", content: [hdr]},
             %Node{type: "table_row", content: [bdy]}
           ] = content

    assert hdr.type == "table_header"
    assert hdr.attrs["align"] == "right"
    assert bdy.type == "table_cell"
  end

  test "Figure maps to div.figure preserving content and caption" do
    fig = %Panpipe.AST.Figure{
      caption: %Panpipe.AST.Caption{blocks: [para("cap")]},
      attr: %Panpipe.AST.Attr{},
      children: [para("body")]
    }

    assert [%Node{type: "div", attrs: attrs, content: content}] = Block.map_blocks([fig], [])
    assert attrs["classes"] == ["figure"]
    assert length(content) == 2
  end

  test "HorizontalRule maps to horizontal_rule" do
    assert [%Node{type: "horizontal_rule"}] =
             Block.map_blocks([%Panpipe.AST.HorizontalRule{}], [])
  end
end
