defmodule Canonical.Import.Attrs do
  @moduledoc """
  Converts a Panpipe.AST.Attr into a canonical attrs map.

  The original Pandoc identifier is preserved as `"source_id"` (a human-meaningful
  cross-reference anchor, e.g. a heading slug), kept SEPARATE from the stable
  node `"id"` which is minted later by `Canonical.Id`. This lets internal
  cross-references (`[x](#slug)`) resolve while comment anchoring rides on the
  stable minted id.
  """

  def to_map(%Panpipe.AST.Attr{identifier: id, classes: classes, key_value_pairs: kv}) do
    %{}
    |> put_if("source_id", id, &(&1 not in [nil, ""]))
    |> put_if("classes", classes, &(&1 != []))
    |> put_if("attrs", kv, &(is_map(&1) and map_size(&1) > 0))
  end

  def add_class(attrs, class) do
    Map.update(attrs, "classes", [class], fn classes ->
      if class in classes, do: classes, else: classes ++ [class]
    end)
  end

  defp put_if(map, key, value, pred) do
    if pred.(value), do: Map.put(map, key, value), else: map
  end
end
