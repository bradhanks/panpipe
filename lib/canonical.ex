defmodule Canonical do
  @moduledoc """
  Canonical, ProseMirror-shaped, schema-validated document model with Pandoc import.

  `ingest/2` and `import_document/2` are the entry points; both are named to avoid
  clashing with `Kernel.SpecialForms.import/2`.
  """
  alias Canonical.{Import, PM, Text}
  alias Canonical.Schema.Pandoc

  defdelegate ingest(input_or_opts, opts \\ []), to: Import
  defdelegate from_panpipe(document, opts \\ []), to: Import
  defdelegate to_pm_json(node), to: Import
  defdelegate from_pm_json(map), to: Import

  defdelegate flatten_text(node), to: Text
  defdelegate utf16_length(string), to: Text
  defdelegate utf16_slice(string, from, to), to: Text

  @doc """
  Validates a canonical doc. Accepts either a `%Canonical.Node{}` or a plain PM
  JSON map. Returns `:ok | {:error, [%{path: String.t(), message: String.t()}]}`.
  """
  def validate(doc, schema \\ Pandoc.schema())
  def validate(%Canonical.Node{} = node, schema), do: Import.validate(node, schema)
  def validate(doc, schema) when is_map(doc), do: doc |> PM.from_json() |> Import.validate(schema)

  @doc """
  Imports a source document into a PM JSON map + metadata.

  Accepts a binary (temp-filed for pandoc; format from `opts[:source_format]`) or a
  panpipe options keyword list (e.g. `[input: path, from: :docx]`). Returns
  `{:ok, %{doc: map(), meta: map(), warnings: [term()]}} | {:error, term()}`.
  """
  def import_document(content_or_opts, opts \\ [])

  def import_document(content, opts) when is_binary(content) do
    ast_opts =
      case Keyword.get(opts, :source_format) do
        nil -> []
        fmt -> [from: String.to_atom(fmt)]
      end

    tmp = Path.join(System.tmp_dir!(), "canonical_import_#{:erlang.unique_integer([:positive])}")
    File.write!(tmp, content)

    try do
      run_import([input: tmp] ++ ast_opts, opts)
    after
      File.rm(tmp)
    end
  end

  def import_document(in_opts, opts) when is_list(in_opts), do: run_import(in_opts, opts)

  defp run_import(in_opts, opts) do
    canonical_opts = Keyword.take(opts, [:id_generator, :preserve_soft_breaks, :on_invalid])

    case ingest(in_opts, canonical_opts) do
      {:ok, struct_doc, warnings} ->
        doc = PM.to_json(struct_doc)
        {:ok, %{doc: doc, meta: build_meta(doc, opts), warnings: warnings}}

      {:error, _} = error ->
        error
    end
  end

  defp build_meta(doc, opts) do
    title =
      case doc["content"] |> List.wrap() |> Enum.find(&(&1["type"] == "heading")) do
        nil -> nil
        heading -> Text.flatten_text(heading)
      end

    %{
      "title" => title,
      "word_count" => doc |> Text.flatten_text() |> word_count(),
      "source_format" => Keyword.get(opts, :source_format)
    }
  end

  defp word_count(""), do: 0
  defp word_count(text), do: text |> String.split(~r/\s+/, trim: true) |> length()

  @doc "The default schema (the custom Pandoc-covering schema)."
  def schema, do: Pandoc.schema()
end
