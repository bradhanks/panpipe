defmodule Canonical.Schema.Validator do
  @moduledoc "Validates a Canonical.Node tree against a Canonical.Schema."
  alias Canonical.Node
  alias Canonical.Schema
  alias Canonical.Schema.ContentExpr

  @doc "Returns :ok or {:error, [%{path: String.t(), message: String.t()}]}."
  def validate(%Node{} = node, %Schema{} = schema) do
    case do_validate(node, schema, "$") do
      [] -> :ok
      violations -> {:error, violations}
    end
  end

  defp do_validate(%Node{type: type} = node, schema, path) do
    case Schema.node_spec(schema, type) do
      :error ->
        [v(path, "unknown node type #{inspect(type)}")]

      {:ok, spec} ->
        check_text(node, spec, path) ++
          check_attrs(node, spec, path) ++
          check_content(node, spec, schema, path) ++
          check_child_marks(node, spec, schema, path) ++
          children_violations(node, schema, path)
    end
  end

  defp check_text(%Node{type: "text", text: t}, %{text?: true}, _path) when is_binary(t), do: []

  defp check_text(%Node{type: "text"}, %{text?: true}, path),
    do: [v(path, "text node missing string")]

  defp check_text(%Node{text: nil}, %{text?: false}, _path), do: []
  defp check_text(%Node{text: _}, %{text?: false}, path), do: [v(path, "non-text node has text")]
  defp check_text(_, _, _), do: []

  defp check_attrs(%Node{attrs: attrs}, %{attrs: specs}, path) do
    Enum.flat_map(specs, fn {name, attr_spec} ->
      cond do
        Map.has_key?(attrs, name) -> []
        Map.has_key?(attr_spec, :default) -> []
        true -> [v(path, "missing attr #{name}")]
      end
    end)
  end

  defp check_content(%Node{content: content}, %{content: expr_str}, schema, path) do
    expr = ContentExpr.parse(expr_str || "")
    types = Enum.map(content, & &1.type)

    if ContentExpr.matches?(expr, types, schema) do
      []
    else
      [v(path, "content #{inspect(types)} does not satisfy #{inspect(expr_str)}")]
    end
  end

  defp check_child_marks(%Node{content: content}, %{marks: allowed}, _schema, path) do
    content
    |> Enum.with_index()
    |> Enum.flat_map(fn {child, i} ->
      Enum.flat_map(child.marks, fn mark ->
        if Schema.mark_allowed?(allowed, mark.type),
          do: [],
          else: [v("#{path}/content[#{i}]", "mark #{mark.type} not allowed here")]
      end)
    end)
  end

  defp children_violations(%Node{content: content}, schema, path) do
    content
    |> Enum.with_index()
    |> Enum.flat_map(fn {child, i} -> do_validate(child, schema, "#{path}/content[#{i}]") end)
  end

  defp v(path, message), do: %{path: path, message: message}
end
