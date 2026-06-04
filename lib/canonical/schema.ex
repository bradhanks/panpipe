defmodule Canonical.Schema do
  @moduledoc "Declarative ProseMirror-style schema as data."

  defmodule NodeSpec do
    @moduledoc "Spec for a single node type."
    # content: a content-expression string, or nil for leaf/atom nodes.
    # group:   space-separated group names (e.g. "block"); nil for none.
    # attrs:   %{name => %{default: value}} ; absence of :default means required.
    # marks:   :all | [mark_name] | nil  — which marks are allowed on inline children.
    # inline:  true for inline nodes. atom: leaf node. text?: the text node.
    defstruct content: nil,
              group: nil,
              inline: false,
              atom: false,
              attrs: %{},
              marks: nil,
              text?: false
  end

  defmodule MarkSpec do
    @moduledoc "Spec for a single mark type."
    defstruct attrs: %{}
  end

  defstruct nodes: %{}, marks: %{}, top_node: "doc"

  def node_spec(%__MODULE__{nodes: nodes}, type), do: Map.fetch(nodes, type)

  def mark_spec(%__MODULE__{marks: marks}, type), do: Map.fetch(marks, type)

  @doc "Group names for a node type (empty list if unknown or ungrouped)."
  def groups(%__MODULE__{} = schema, type) do
    case node_spec(schema, type) do
      {:ok, %NodeSpec{group: nil}} -> []
      {:ok, %NodeSpec{group: group}} -> String.split(group)
      :error -> []
    end
  end

  def mark_allowed?(:all, _type), do: true
  def mark_allowed?(nil, _type), do: false
  def mark_allowed?(list, type) when is_list(list), do: type in list
end
