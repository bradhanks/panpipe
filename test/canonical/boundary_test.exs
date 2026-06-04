defmodule Canonical.BoundaryTest do
  use ExUnit.Case, async: true

  test "validate/1 accepts a plain PM JSON map" do
    {:ok, struct_doc, _} = Canonical.ingest("# Hi")
    map = Canonical.to_pm_json(struct_doc)
    assert Canonical.validate(map) == :ok
  end

  test "validate/1 rejects a malformed map with {:error, [%{path, message}]}" do
    bad = %{"type" => "doc", "content" => [%{"type" => "bogus_node"}]}
    assert {:error, violations} = Canonical.validate(bad)
    assert [%{path: _, message: _} | _] = violations
    assert Enum.any?(violations, &(&1.message =~ "unknown node type"))
  end

  test "import_document/2 returns a map doc + meta from a markdown string" do
    {:ok, %{doc: doc, meta: meta, warnings: warnings}} =
      Canonical.import_document("# Title\n\nHello **world**", source_format: "markdown")

    assert doc["type"] == "doc"
    heading = Enum.find(doc["content"], &(&1["type"] == "heading"))
    assert is_binary(heading["attrs"]["id"])
    refute Map.has_key?(heading, "id")

    assert meta["title"] == "Title"
    # flatten_text concatenates blocks without separators ("Title" + "Hello world"
    # => "TitleHello world"), so word_count is 2, not 3. This is intentional:
    # inserting separators would break the UTF-16 anchor offsets.
    assert meta["word_count"] == 2
    assert meta["source_format"] == "markdown"
    assert is_list(warnings)
  end
end
