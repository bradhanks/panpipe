defmodule Canonical.Import do
  @moduledoc "Orchestrates Panpipe IR → canonical tree → minted ids → validation."
  alias Canonical.{Node, Id, Schema, PM}
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

    ast_result =
      case input_or_opts do
        input when is_binary(input) -> Panpipe.ast(input, pandoc_opts)
        list when is_list(list) -> Panpipe.ast(Keyword.merge(list, pandoc_opts))
      end

    case ast_result do
      {:ok, %Panpipe.Document{} = doc} -> from_panpipe(doc, canonical_opts)
      {:error, _} = error -> error
    end
  end

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
