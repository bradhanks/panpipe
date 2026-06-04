defmodule Canonical.LegacyDocTest do
  use ExUnit.Case, async: false
  alias Canonical.Node

  @fixture Path.join(__DIR__, "fixtures/legacy.doc")

  @tag :libreoffice
  test "ingest transparently converts a legacy binary .doc into a validated AST" do
    {:ok, doc, _warnings} = Canonical.ingest(input: @fixture)

    assert %Node{type: "doc"} = doc
    assert :ok == Canonical.validate(doc)

    # Block structure survives the legacy .doc -> docx -> pandoc round-trip.
    types = Enum.map(doc.content, & &1.type)
    assert "heading" in types
    assert "bullet_list" in types
    assert "blockquote" in types

    # The heading text comes through intact.
    [heading | _] = Enum.filter(doc.content, &(&1.type == "heading"))
    assert text_of(heading) =~ "Quarterly Report"

    # NOTE: table STRUCTURE does NOT reliably survive the binary .doc format
    # (LibreOffice flattens it on conversion). This is a limitation of the legacy
    # .doc path, not of the importer — modern .docx preserves tables (see
    # Canonical.ImportTest / properties). We assert the loss explicitly so the
    # behavior is documented rather than silently assumed.
    refute "table" in types
  end

  defp text_of(%Node{type: "text", text: t}), do: t
  defp text_of(%Node{content: content}), do: Enum.map_join(content, &text_of/1)
  defp text_of(_), do: ""
end
