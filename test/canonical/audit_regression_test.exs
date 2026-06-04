defmodule Canonical.AuditRegressionTest do
  @moduledoc "Regression tests for the 9 audit findings (2026-06-04)."
  use ExUnit.Case, async: true

  alias Canonical.{Node, Schema, Text, Id}
  alias Canonical.Import.{Inline, Block}

  defp s(str), do: %Panpipe.AST.Str{string: str}

  # --- #1 nested same-type marks merge instead of dropping inner attrs ---
  test "nested span marks union their classes (inner attrs preserved)" do
    inner = %Panpipe.AST.Span{children: [s("t")], attr: %Panpipe.AST.Attr{classes: ["inner"]}}
    outer = %Panpipe.AST.Span{children: [inner], attr: %Panpipe.AST.Attr{classes: ["outer"]}}

    assert [%Node{type: "text", text: "t", marks: [m]}] = Inline.flatten([outer], [])
    assert m.type == "span"
    assert Enum.sort(m.attrs["classes"]) == ["inner", "outer"]
  end

  test "nested links collapse to one link mark with inner href winning" do
    inner = %Panpipe.AST.Link{children: [s("t")], target: "http://inner", title: ""}
    outer = %Panpipe.AST.Link{children: [inner], target: "http://outer", title: ""}

    assert [%Node{type: "text", marks: [m]}] = Inline.flatten([outer], [])
    assert m.type == "link"
    assert m.attrs["href"] == "http://inner"
  end

  test "nested spans deep-merge their key-value attrs (outer kv preserved)" do
    inner = %Panpipe.AST.Span{
      children: [s("t")],
      attr: %Panpipe.AST.Attr{key_value_pairs: %{"data-b" => "2"}}
    }

    outer = %Panpipe.AST.Span{
      children: [inner],
      attr: %Panpipe.AST.Attr{key_value_pairs: %{"data-a" => "1"}}
    }

    assert [%Node{type: "text", marks: [m]}] = Inline.flatten([outer], [])
    assert m.attrs["attrs"] == %{"data-a" => "1", "data-b" => "2"}
  end

  # --- #2 empty Str produces no empty text node ---
  test "empty Str yields no node, and empties never survive coalescing" do
    assert Inline.flatten([s("")], []) == []
    assert [%Node{type: "text", text: "ab"}] = Inline.flatten([s("a"), s(""), s("b")], [])
  end

  # --- #3 table row_head_columns: leading stub cells become table_header ---
  test "table body stub cells (row_head_columns) are typed as table_header" do
    cell = fn t ->
      %Panpipe.AST.Cell{
        blocks: [%Panpipe.AST.Para{children: [s(t)]}],
        alignment: "AlignDefault",
        row_span: 1,
        col_span: 1
      }
    end

    row = %Panpipe.AST.Row{cells: [cell.("stub"), cell.("data")]}

    body = %Panpipe.AST.TableBody{
      row_head_columns: 1,
      intermediate_head_rows: [],
      intermediate_body_rows: [row]
    }

    table = %Panpipe.AST.Table{
      col_spec: [],
      table_head: %Panpipe.AST.TableHead{rows: []},
      table_bodies: [body],
      table_foot: %Panpipe.AST.TableFoot{rows: []},
      caption: %Panpipe.AST.Caption{blocks: []},
      attr: %Panpipe.AST.Attr{}
    }

    assert [%Node{type: "table", content: [%Node{type: "table_row", content: [stub, data]}]}] =
             Block.map_blocks([table], [])

    assert stub.type == "table_header"
    assert data.type == "table_cell"
  end

  # --- #4 definition list with no definitions stays schema-valid ---
  test "definition term with zero definitions yields a def_desc and validates" do
    dl = %Panpipe.AST.DefinitionList{children: [[[s("Term")], []]]}

    assert [%Node{type: "definition_list", content: content}] = Block.map_blocks([dl], [])

    assert [
             %Node{type: "def_term"},
             %Node{type: "def_desc", content: [%Node{type: "paragraph", content: []}]}
           ] = content

    assert {:ok, _doc, _warnings} = Canonical.from_panpipe(%Panpipe.Document{children: [dl]})
  end

  # --- #5 empty figure -> empty div validates (div is block*) ---
  test "empty figure maps to an empty div that validates" do
    fig = %Panpipe.AST.Figure{
      caption: %Panpipe.AST.Caption{blocks: []},
      attr: %Panpipe.AST.Attr{},
      children: []
    }

    assert {:ok, tree, _} = Canonical.from_panpipe(%Panpipe.Document{children: [fig]})
    assert [%Node{type: "div", content: []}] = tree.content
  end

  # --- #6 utf16_slice recovers valid prefix on a split surrogate ---
  test "utf16_slice keeps the valid prefix when a slice ends mid-surrogate" do
    assert Text.utf16_slice("hi😂", 0, 3) == "hi"
    assert Text.utf16_slice("a😂b", 0, 2) == "a"
  end

  # --- #7 minted id colliding with a later authored id does not warn ---
  test "a minted id colliding with a later authored id stays unique without a spurious warning" do
    {:ok, pid} = Agent.start_link(fn -> ~w(A B C D) end)
    gen = fn -> Agent.get_and_update(pid, fn [h | t] -> {h, t} end) end

    tree = %Node{
      type: "doc",
      content: [%Node{type: "paragraph", attrs: %{"id" => "A"}, content: []}]
    }

    {minted, warnings} = Id.mint(tree, id_generator: gen)

    assert minted.attrs["id"] == "A"
    [p] = minted.content
    assert p.attrs["id"] != "A"
    refute Enum.any?(warnings, &match?({:duplicate_id, _}, &1))
  end

  # --- #8 import_document accepts an atom source_format ---
  test "import_document/2 accepts an atom source_format" do
    assert {:ok, %{doc: doc}} = Canonical.import_document("# T\n\nx", source_format: :markdown)
    assert doc["type"] == "doc"
  end

  # --- #9 import_document forwards a custom :schema ---
  test "import_document/2 forwards a custom :schema to validation" do
    empty = %Schema{nodes: %{}, marks: %{}, top_node: "doc"}

    assert {:error, {:invalid, _}} =
             Canonical.import_document("# T", source_format: :markdown, schema: empty)
  end
end
