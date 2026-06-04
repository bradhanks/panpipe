# Deferred / parked code

This directory is a **placeholder bucket** for code that is intentionally *not*
part of the MVP build. Nothing here is compiled or tested — it lives outside
`lib/` and `test/` on purpose.

**MVP scope (current):** import **docx only** (via pandoc) → canonical
ProseMirror-shaped AST. That path lives in `lib/canonical/` and is fully tested.

## What's parked here

### `legacy-word/` — legacy binary Word import (.doc/.dot/.wri)
Transparent LibreOffice (`soffice --convert-to docx`) fallback that let
`Canonical.ingest` accept pre-2007 Word files. Pulled out for the docx-only MVP.

- `lib/convert.ex` → was `lib/canonical/convert.ex` (`Canonical.Convert`)
- `test/convert_test.exs`, `test/legacy_doc_test.exs`, `test/fixtures/legacy.doc`

**Known limitation when restored:** block structure (headings/lists/quotes)
survives, but **table structure degrades** through the binary `.doc` round-trip
(a LibreOffice/format limitation, not the importer).

**To restore:** move `lib/convert.ex` back to `lib/canonical/convert.ex` and the
test files back under `test/canonical/`, then re-add the `Convert` wiring in
`Canonical.Import.ingest/2` (route file input through
`Convert.to_pandoc_readable/1` before `Panpipe.ast`). Requires LibreOffice
(`brew install --cask libreoffice`).

## Also deferred (no code yet)

- **PDF import.** Needs a dedicated self-hosted structured-extraction engine
  (Docling / Marker / MinerU / pdfium+Tesseract, etc.) — *not* a docx round-trip,
  which produces frame-soup. Kicked down the road; see the (incomplete) research
  attempt in chat history. The canonical AST is engine-agnostic, so a PDF importer
  can be added later as a parallel front-end without touching the core.
- **Export** (canonical AST → other formats) — separate future phase.
