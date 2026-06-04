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
end
