defmodule Canonical.Id do
  @moduledoc """
  Stable identifier generation and the tree-minting pass.

  IDs use a 64-character URL-safe alphabet with 6-bit masking (`band(byte, 63)`),
  which is bias-free because the alphabet size divides 256 evenly — unlike a naive
  `rem(byte, 62)`, which would skew the character distribution.
  """
  import Bitwise

  # Exactly 64 URL-safe characters.
  @alphabet ~c"0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz-_"

  @doc "Generate a random URL-safe id of the given length (default 12)."
  def generate(length \\ 12) when length > 0 do
    :crypto.strong_rand_bytes(length)
    |> :binary.bin_to_list()
    |> Enum.map(fn byte -> Enum.at(@alphabet, band(byte, 63)) end)
    |> List.to_string()
  end

  alias Canonical.Node

  @doc """
  Walk the tree assigning `attrs["id"]` to every non-text node.

  Preserves an existing non-empty id; if a preserved id collides with one already
  seen, mints a fresh one and records a `{:duplicate_id, id}` warning. Returns
  `{tree, warnings}`.
  """
  def mint(%Node{} = tree, opts \\ []) do
    gen = Keyword.get(opts, :id_generator, &generate/0)
    {minted, _seen, warnings} = mint_node(tree, MapSet.new(), [], gen)
    {minted, Enum.reverse(warnings)}
  end

  defp mint_node(%Node{type: "text"} = node, seen, warnings, _gen), do: {node, seen, warnings}

  defp mint_node(%Node{} = node, seen, warnings, gen) do
    {id, seen, warnings} = resolve_id(Map.get(node.attrs, "id"), seen, warnings, gen)

    {content, seen, warnings} =
      Enum.reduce(node.content, {[], seen, warnings}, fn child, {acc, s, w} ->
        {minted, s2, w2} = mint_node(child, s, w, gen)
        {[minted | acc], s2, w2}
      end)

    {%{node | attrs: Map.put(node.attrs, "id", id), content: Enum.reverse(content)}, seen,
     warnings}
  end

  defp resolve_id(existing, seen, warnings, gen) when is_binary(existing) and existing != "" do
    if MapSet.member?(seen, existing) do
      fresh = fresh_id(seen, gen)
      {fresh, MapSet.put(seen, fresh), [{:duplicate_id, existing} | warnings]}
    else
      {existing, MapSet.put(seen, existing), warnings}
    end
  end

  defp resolve_id(_missing, seen, warnings, gen) do
    fresh = fresh_id(seen, gen)
    {fresh, MapSet.put(seen, fresh), warnings}
  end

  defp fresh_id(seen, gen) do
    id = gen.()
    if MapSet.member?(seen, id), do: fresh_id(seen, gen), else: id
  end
end
