defmodule Canonical.PM do
  @moduledoc "Serialize/deserialize Canonical.Node trees to literal ProseMirror JSON."
  alias Canonical.{Node, Mark}

  def to_json(%Node{type: "text", text: text, marks: marks}) do
    base = %{"type" => "text", "text" => text}
    if marks == [], do: base, else: Map.put(base, "marks", Enum.map(marks, &mark_json/1))
  end

  def to_json(%Node{type: type, attrs: attrs, content: content, marks: marks}) do
    %{"type" => type}
    |> maybe_put("attrs", if(attrs == %{}, do: nil, else: attrs))
    |> maybe_put("content", if(content == [], do: nil, else: Enum.map(content, &to_json/1)))
    |> maybe_put("marks", if(marks == [], do: nil, else: Enum.map(marks, &mark_json/1)))
  end

  def from_json(%{"type" => "text"} = map) do
    %Node{type: "text", text: Map.get(map, "text", ""), marks: marks_from(map)}
  end

  def from_json(%{"type" => type} = map) do
    %Node{
      type: type,
      attrs: Map.get(map, "attrs", %{}),
      content: Enum.map(Map.get(map, "content", []), &from_json/1),
      marks: marks_from(map)
    }
  end

  defp mark_json(%Mark{type: type, attrs: attrs}) do
    base = %{"type" => type}
    if attrs == %{}, do: base, else: Map.put(base, "attrs", attrs)
  end

  defp marks_from(map) do
    map
    |> Map.get("marks", [])
    |> Enum.map(fn %{"type" => type} = m ->
      %Mark{type: type, attrs: Map.get(m, "attrs", %{})}
    end)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
