defmodule Canonical do
  @moduledoc """
  Canonical, ProseMirror-shaped, schema-validated document model with Pandoc import.

  `ingest/2` is the spec's "import" entry point; it is named `ingest` to avoid
  clashing with `Kernel.SpecialForms.import/2`.
  """
  alias Canonical.Import
  alias Canonical.Schema.Pandoc

  defdelegate ingest(input_or_opts, opts \\ []), to: Import
  defdelegate from_panpipe(document, opts \\ []), to: Import
  defdelegate to_pm_json(node), to: Import
  defdelegate from_pm_json(map), to: Import

  def validate(node, schema \\ Pandoc.schema()), do: Import.validate(node, schema)

  @doc "The default schema (the custom Pandoc-covering schema)."
  def schema, do: Pandoc.schema()
end
