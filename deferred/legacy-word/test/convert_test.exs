defmodule Canonical.ConvertTest do
  # soffice is heavy and global-ish; keep these serial.
  use ExUnit.Case, async: false
  alias Canonical.Convert

  @fixture Path.join(__DIR__, "fixtures/legacy.doc")

  test "passes through formats pandoc already reads" do
    assert {:ok, "/x/y.docx"} = Convert.to_pandoc_readable("/x/y.docx")
    assert {:ok, "/x/y.md"} = Convert.to_pandoc_readable("/x/y.md")
    assert {:ok, "/x/y.html"} = Convert.to_pandoc_readable("/x/y.html")
  end

  test "missing legacy file yields an :enoent error" do
    assert {:error, {:enoent, _}} = Convert.to_pandoc_readable("/nope/missing.doc")
  end

  @tag :libreoffice
  test "converts a legacy .doc to a temporary .docx and cleans up" do
    assert {:ok, docx} = Convert.to_pandoc_readable(@fixture)
    assert String.ends_with?(docx, ".docx")
    assert File.exists?(docx)

    Convert.cleanup(docx)
    refute File.exists?(docx)
  end
end
