defmodule Canonical.Text do
  @moduledoc """
  Text flattening and UTF-16 offset helpers for canonical document maps.

  `flatten_text/1` takes a node **map** (string keys) and returns the concatenated
  descendant text. `utf16_length/1` and `utf16_slice/3` operate on the resulting
  **string** and compute offsets in UTF-16 code units (to align with the JS /
  ProseMirror frontend, which addresses text in UTF-16). `utf16_slice/3` takes
  `(string, from, to)` END-offsets (not a length).
  """

  @spec flatten_text(map()) :: String.t()
  def flatten_text(node), do: node |> io_text() |> IO.iodata_to_binary()

  defp io_text(%{"type" => "text", "text" => t}) when is_binary(t), do: t
  defp io_text(%{"content" => content}) when is_list(content), do: Enum.map(content, &io_text/1)
  defp io_text(_), do: []

  @spec utf16_length(String.t()) :: non_neg_integer()
  def utf16_length(string) when is_binary(string) do
    div(byte_size(:unicode.characters_to_binary(string, :utf8, {:utf16, :little})), 2)
  end

  @spec utf16_slice(String.t(), non_neg_integer(), non_neg_integer()) :: String.t()
  def utf16_slice(string, from, to)
      when is_binary(string) and is_integer(from) and is_integer(to) and from >= 0 and to >= from do
    u16 = :unicode.characters_to_binary(string, :utf8, {:utf16, :little})
    total = byte_size(u16)
    byte_from = min(from * 2, total)
    byte_to = min(to * 2, total)
    len = byte_to - byte_from

    if len <= 0 do
      ""
    else
      u16
      |> binary_part(byte_from, len)
      |> :unicode.characters_to_binary({:utf16, :little}, :utf8)
    end
  end
end
