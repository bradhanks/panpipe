defmodule Canonical.Convert do
  @moduledoc """
  Normalizes source files that pandoc cannot read directly into a pandoc-readable
  format, using LibreOffice (`soffice`) headless conversion.

  Currently handles the legacy binary Word family (`.doc`/`.dot`/`.wri`) — which
  pandoc cannot parse — by converting to `.docx`. Formats pandoc already reads are
  returned unchanged. PDF is intentionally NOT handled here (it needs a dedicated
  structured-extraction engine, not a docx round-trip).
  """

  # Legacy/binary formats pandoc can't parse but LibreOffice can, → docx.
  @needs_conversion ~w(.doc .dot .wri)

  @doc """
  Returns `{:ok, path}` for a path pandoc can already read, `{:ok, converted_path}`
  after converting a legacy format to `.docx` (caller must `cleanup/1` the result),
  or `{:error, reason}`.
  """
  def to_pandoc_readable(path) when is_binary(path) do
    ext = path |> Path.extname() |> String.downcase()

    if ext in @needs_conversion do
      convert_to_docx(path)
    else
      {:ok, path}
    end
  end

  @doc "Remove the temporary directory holding a converted file."
  def cleanup(converted_path) when is_binary(converted_path) do
    converted_path |> Path.dirname() |> File.rm_rf()
    :ok
  end

  @doc "Whether a LibreOffice `soffice` binary is available."
  def converter_available?, do: soffice() != nil

  defp convert_to_docx(path) do
    cond do
      not File.exists?(path) ->
        {:error, {:enoent, path}}

      soffice() == nil ->
        {:error,
         {:converter_missing,
          "LibreOffice (soffice) is required to import #{Path.extname(path)} files " <>
            "but was not found on PATH or in /Applications"}}

      true ->
        run_soffice(path)
    end
  end

  defp run_soffice(path) do
    outdir =
      Path.join(System.tmp_dir!(), "canonical_convert_#{:erlang.unique_integer([:positive])}")

    File.mkdir_p!(outdir)
    # Per-call profile dir avoids "another instance is running" lock conflicts.
    profile = "file://" <> Path.join(outdir, "lo_profile")

    args = [
      "-env:UserInstallation=#{profile}",
      "--headless",
      "--convert-to",
      "docx",
      "--outdir",
      outdir,
      path
    ]

    case System.cmd(soffice(), args, stderr_to_stdout: true) do
      {_out, 0} ->
        docx = Path.join(outdir, Path.rootname(Path.basename(path)) <> ".docx")

        if File.exists?(docx) do
          {:ok, docx}
        else
          File.rm_rf(outdir)
          {:error, {:conversion_failed, "soffice exited 0 but produced no .docx"}}
        end

      {out, code} ->
        File.rm_rf(outdir)
        {:error, {:conversion_failed, code, out}}
    end
  end

  defp soffice do
    System.find_executable("soffice") || mac_soffice()
  end

  defp mac_soffice do
    path = "/Applications/LibreOffice.app/Contents/MacOS/soffice"
    if File.exists?(path), do: path, else: nil
  end
end
