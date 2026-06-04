defmodule Canonical.Import do
  @moduledoc "Orchestrates Panpipe IR → canonical tree → minted ids → validation."
  alias Canonical.{Node, Id, Schema, PM, Convert}
  alias Canonical.Import.Block
  alias Canonical.Schema.{Pandoc, Validator}

  @escape_types ~w(unsupported_block unsupported_inline raw_block raw_inline)

  # Options consumed by the canonical layer; everything else is forwarded to pandoc.
  @canonical_opts [:id_generator, :preserve_soft_breaks, :on_invalid, :schema]

  @doc """
  Import raw input into a canonical doc.

  `input_or_opts` is a string (or a panpipe options keyword list, e.g.
  `[input: "file.md"]`). `opts` may mix canonical options
  (#{inspect(@canonical_opts)}) with pandoc options (e.g. `from: :html`); they are
  split and routed appropriately.
  """
  def ingest(input_or_opts, opts \\ []) do
    {canonical_opts, pandoc_opts} = Keyword.split(opts, @canonical_opts)

    case input_or_opts do
      input when is_binary(input) ->
        finish(Panpipe.ast(input, pandoc_opts), canonical_opts)

      list when is_list(list) ->
        ingest_opts(Keyword.merge(list, pandoc_opts), canonical_opts)
    end
  end

  # When the input is a file, transparently convert legacy formats (e.g. binary
  # Word `.doc`) to a pandoc-readable form via LibreOffice before parsing.
  defp ingest_opts(pandoc_opts, canonical_opts) do
    case Keyword.get(pandoc_opts, :input) do
      path when is_binary(path) ->
        case Convert.to_pandoc_readable(path) do
          {:ok, ^path} ->
            finish(Panpipe.ast(pandoc_opts), canonical_opts)

          {:ok, converted} ->
            try do
              finish(Panpipe.ast(Keyword.put(pandoc_opts, :input, converted)), canonical_opts)
            after
              Convert.cleanup(converted)
            end

          {:error, _} = error ->
            error
        end

      _ ->
        finish(Panpipe.ast(pandoc_opts), canonical_opts)
    end
  end

  defp finish({:ok, %Panpipe.Document{} = doc}, canonical_opts),
    do: from_panpipe(doc, canonical_opts)

  defp finish({:error, _} = error, _canonical_opts), do: error

  @doc "Convert an already-parsed Panpipe.Document into a canonical doc."
  def from_panpipe(%Panpipe.Document{children: blocks}, opts \\ []) do
    schema = Keyword.get(opts, :schema, Pandoc.schema())
    tree = %Node{type: "doc", content: Block.map_blocks(blocks, opts)}
    {tree, id_warnings} = Id.mint(tree, opts)
    warnings = id_warnings ++ escape_warnings(tree)

    case Keyword.get(opts, :on_invalid, :error) do
      :error ->
        case Validator.validate(tree, schema) do
          :ok -> {:ok, tree, warnings}
          {:error, violations} -> {:error, {:invalid, violations}}
        end

      :warn ->
        extra =
          case Validator.validate(tree, schema) do
            :ok -> []
            {:error, violations} -> [{:invalid, violations}]
          end

        {:ok, tree, warnings ++ extra}
    end
  end

  def to_pm_json(%Node{} = node), do: PM.to_json(node)
  def from_pm_json(map) when is_map(map), do: PM.from_json(map)
  def validate(%Node{} = node, %Schema{} = schema), do: Validator.validate(node, schema)

  defp escape_warnings(%Node{} = node) do
    node
    |> collect()
    |> Enum.filter(&(&1.type in @escape_types))
    |> Enum.map(&{:escaped, &1.type})
  end

  defp collect(%Node{content: content} = node), do: [node | Enum.flat_map(content, &collect/1)]
end
