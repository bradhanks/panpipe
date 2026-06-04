defmodule Canonical.Schema.Pandoc do
  @moduledoc "The custom ProseMirror schema covering the Pandoc feature set."
  alias Canonical.Schema
  alias Canonical.Schema.{NodeSpec, MarkSpec}
  alias Canonical.Mark

  @doc "Returns the schema struct. Cheap to build; callers may memoize if needed."
  def schema do
    %Schema{
      top_node: "doc",
      nodes: nodes(),
      marks: marks()
    }
  end

  defp nodes do
    %{
      "doc" => %NodeSpec{content: "block+"},
      "paragraph" => %NodeSpec{content: "inline*", group: "block", marks: :all, attrs: id_attr()},
      "heading" => %NodeSpec{
        content: "inline*",
        group: "block",
        marks: :all,
        attrs: Map.merge(id_attr(), %{"level" => %{default: 1}})
      },
      "blockquote" => %NodeSpec{content: "block+", group: "block", attrs: id_attr()},
      "code_block" => %NodeSpec{
        content: "text*",
        group: "block",
        marks: nil,
        attrs: Map.merge(id_attr(), %{"language" => %{default: ""}, "classes" => %{default: []}})
      },
      "bullet_list" => %NodeSpec{content: "list_item+", group: "block", attrs: id_attr()},
      "ordered_list" => %NodeSpec{
        content: "list_item+",
        group: "block",
        attrs:
          Map.merge(id_attr(), %{
            "start" => %{default: 1},
            "style" => %{default: "Decimal"},
            "delimiter" => %{default: "Period"}
          })
      },
      "list_item" => %NodeSpec{content: "block+", attrs: id_attr()},
      "horizontal_rule" => %NodeSpec{group: "block", atom: true, attrs: id_attr()},
      "table" => %NodeSpec{
        content: "table_caption? table_row+",
        group: "block",
        attrs: Map.merge(id_attr(), %{"colspec" => %{default: []}})
      },
      "table_caption" => %NodeSpec{content: "block+", attrs: id_attr()},
      "table_row" => %NodeSpec{content: "(table_cell | table_header)+", attrs: id_attr()},
      "table_cell" => %NodeSpec{content: "block+", attrs: cell_attrs()},
      "table_header" => %NodeSpec{content: "block+", attrs: cell_attrs()},
      "definition_list" => %NodeSpec{
        content: "(def_term def_desc+)+",
        group: "block",
        attrs: id_attr()
      },
      "def_term" => %NodeSpec{content: "inline*", marks: :all, attrs: id_attr()},
      "def_desc" => %NodeSpec{content: "block+", attrs: id_attr()},
      "div" => %NodeSpec{
        content: "block*",
        group: "block",
        attrs: Map.merge(id_attr(), %{"classes" => %{default: []}, "attrs" => %{default: %{}}})
      },
      "line_block" => %NodeSpec{content: "block+", group: "block", attrs: id_attr()},
      "raw_block" => %NodeSpec{
        group: "block",
        atom: true,
        attrs: Map.merge(id_attr(), %{"format" => %{default: ""}, "text" => %{default: ""}})
      },
      "unsupported_block" => %NodeSpec{
        group: "block",
        atom: true,
        attrs: Map.merge(id_attr(), %{"pandoc" => %{}})
      },
      "text" => %NodeSpec{text?: true, inline: true, group: "inline"},
      "image" => %NodeSpec{
        inline: true,
        atom: true,
        group: "inline",
        attrs:
          Map.merge(id_attr(), %{
            "src" => %{default: ""},
            "alt" => %{default: ""},
            "title" => %{default: ""}
          })
      },
      "hard_break" => %NodeSpec{inline: true, atom: true, group: "inline", attrs: id_attr()},
      "math" => %NodeSpec{
        inline: true,
        atom: true,
        group: "inline",
        attrs: Map.merge(id_attr(), %{"mode" => %{default: "inline"}, "tex" => %{default: ""}})
      },
      "footnote" => %NodeSpec{content: "block+", inline: true, group: "inline", attrs: id_attr()},
      "raw_inline" => %NodeSpec{
        inline: true,
        atom: true,
        group: "inline",
        attrs: Map.merge(id_attr(), %{"format" => %{default: ""}, "text" => %{default: ""}})
      },
      "unsupported_inline" => %NodeSpec{
        inline: true,
        atom: true,
        group: "inline",
        attrs: Map.merge(id_attr(), %{"pandoc" => %{}})
      }
    }
  end

  defp marks do
    Map.new(Mark.order(), fn name -> {name, mark_spec(name)} end)
  end

  defp mark_spec("link"),
    do: %MarkSpec{attrs: %{"href" => %{default: ""}, "title" => %{default: ""}}}

  defp mark_spec("span"),
    do: %MarkSpec{
      attrs: %{"id" => %{default: ""}, "classes" => %{default: []}, "attrs" => %{default: %{}}}
    }

  defp mark_spec(_), do: %MarkSpec{}

  # `id` is generated during the minting pass, so it always has a default here.
  defp id_attr, do: %{"id" => %{default: ""}}

  defp cell_attrs do
    Map.merge(id_attr(), %{
      "align" => %{default: "default"},
      "rowspan" => %{default: 1},
      "colspan" => %{default: 1}
    })
  end
end
