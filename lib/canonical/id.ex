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
    {minted, _authored, _taken, warnings} = mint_node(tree, MapSet.new(), MapSet.new(), [], gen)
    {minted, Enum.reverse(warnings)}
  end

  defp mint_node(%Node{type: "text"} = node, authored, taken, warnings, _gen),
    do: {node, authored, taken, warnings}

  defp mint_node(%Node{} = node, authored, taken, warnings, gen) do
    {id, authored, taken, warnings} =
      resolve_id(Map.get(node.attrs, "id"), authored, taken, warnings, gen)

    {content, authored, taken, warnings} =
      Enum.reduce(node.content, {[], authored, taken, warnings}, fn child, {acc, a, t, w} ->
        {minted, a2, t2, w2} = mint_node(child, a, t, w, gen)
        {[minted | acc], a2, t2, w2}
      end)

    {%{node | attrs: Map.put(node.attrs, "id", id), content: Enum.reverse(content)}, authored,
     taken, warnings}
  end

  # `authored` = author-supplied ids actually kept; `taken` = every id in use
  # (authored + minted), used only to guarantee minted ids never collide.
  defp resolve_id(existing, authored, taken, warnings, gen)
       when is_binary(existing) and existing != "" do
    cond do
      MapSet.member?(authored, existing) ->
        # genuine author-vs-author duplicate → mint a fresh id and warn
        fresh = fresh_id(taken, gen)
        {fresh, authored, MapSet.put(taken, fresh), [{:duplicate_id, existing} | warnings]}

      MapSet.member?(taken, existing) ->
        # collides only with a previously-minted random id (astronomically rare);
        # mint a fresh id but do NOT warn — it is not an authored duplicate
        fresh = fresh_id(taken, gen)
        {fresh, MapSet.put(authored, fresh), MapSet.put(taken, fresh), warnings}

      true ->
        {existing, MapSet.put(authored, existing), MapSet.put(taken, existing), warnings}
    end
  end

  defp resolve_id(_missing, authored, taken, warnings, gen) do
    fresh = fresh_id(taken, gen)
    {fresh, authored, MapSet.put(taken, fresh), warnings}
  end

  defp fresh_id(taken, gen) do
    id = gen.()
    if MapSet.member?(taken, id), do: fresh_id(taken, gen), else: id
  end
end
