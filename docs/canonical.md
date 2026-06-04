# Canonical — the ProseMirror-shaped document engine

`Canonical.*` is a self-contained document model layered on top of panpipe's
Pandoc bridge. It turns any Pandoc-readable source into a **typed,
schema-validated, ProseMirror-shaped AST** with stable per-node ids, and provides
the helpers consumers need to render it and anchor annotations to it.

It is a **pure library**: no Phoenix, Ecto, Oban, or process state. Everything is
plain functions over plain data (the public boundary speaks maps; structs are an
internal detail).

## Pipeline

```
source bytes / file
   │  Panpipe.ast  (Pandoc → panpipe IR; reused untouched)
   ▼
%Panpipe.Document{}            nested, Pandoc-shaped IR (inline = nested nodes)
   │  Canonical.Import.{Block,Inline}
   ▼
%Canonical.Node{} tree         ProseMirror-shaped (inline = flat text + marks); no ids yet
   │  Canonical.Id.mint         (mint/preserve/de-dupe stable ids)
   ▼
%Canonical.Node{} tree         + attrs["id"] on every block/atomic node
   │  Canonical.Schema.Validator
   ▼
:ok | {:error, violations}     gate (default: hard-fail)
   │  Canonical.PM.to_json
   ▼
ProseMirror JSON map           {type, attrs, content, marks, text}
```

## The node model

One uniform struct (mirrors ProseMirror's real shape):

```elixir
%Canonical.Node{
  type:    "paragraph",     # a node-type name declared in the schema
  attrs:   %{"id" => ...},  # "id" on every block/atomic node; never on text
  content: [%Node{} | ...], # child nodes; [] for leaf/atom nodes
  marks:   [%Mark{}],       # inline formatting; only on inline nodes
  text:    nil              # set only when type == "text"
}

%Canonical.Mark{type: "strong", attrs: %{}}
```

Pandoc nests inline formatting (`Emph [Strong [Str]]`); Canonical **flattens** it
into ProseMirror's model — flat `text` nodes carrying a set of `marks`, with
adjacent equal-mark runs coalesced and marks kept in a deterministic schema-rank
order. Only one mark of a given type is allowed per text node; nesting two of the
same type (e.g. span-in-span) **merges** their attrs (classes are unioned, inner
wins on scalar conflicts).

### `id` vs `source_id` (important)

- **`attrs["id"]`** — a *stable, always-minted* identifier (collision-resistant,
  URL-safe). It exists for **comment/annotation anchoring** and CRDT-readiness. It
  is not derived from content, so it survives edits/re-renders.
- **`attrs["source_id"]`** — the *original Pandoc identifier* (e.g. a heading slug
  from `# Intro {#intro}`), preserved verbatim. It exists for **internal
  cross-references** (`[see](#intro)`): a consumer renders an invisible anchor with
  this id so `#intro` links resolve.

These are deliberately separate: anchoring needs stability, cross-references need
human-meaningful slugs. Pandoc identifiers never become the node `id`.

## The schema

`Canonical.Schema.Pandoc.schema/0` declares the node and mark types, as data
(à la ProseMirror's `Schema`). Validation (`Canonical.Schema.Validator`) checks
node types exist, content matches each node's content-expression
(`block+`, `inline*`, `(table_cell | table_header)+`, …), marks are allowed by the
parent, required attrs are present, and `text` is set iff `type == "text"`.

**Block nodes:** `doc`, `paragraph`, `heading`(level), `blockquote`,
`code_block`(language), `bullet_list`, `ordered_list`(start/style/delimiter),
`list_item`, `horizontal_rule`, `table`/`table_row`/`table_cell`/`table_header`/`table_caption`,
`definition_list`/`def_term`/`def_desc`, `div`(classes), `line_block`, plus escape
nodes `raw_block`(format/text) and `unsupported_block`(original Pandoc JSON).

**Inline nodes:** `text`, `image`(src/alt/title), `hard_break`, `math`(mode/tex),
`footnote`(block content), plus escape `raw_inline` and `unsupported_inline`.

**Marks:** `em`, `strong`, `code`, `link`(href/title), `strikethrough`,
`superscript`, `subscript`, `smallcaps`, `underline`, `span`(id/classes/attrs).

**Escape nodes** keep the SSoT lossless: anything Pandoc emits that the schema
can't represent natively is preserved (raw HTML/LaTeX → `raw_*`; truly unknown →
`unsupported_*` carrying the original Pandoc JSON). `Canonical.import_document/2`
returns a `warnings` list noting where escapes were produced.

## UTF-16 anchoring

Browser/ProseMirror text offsets count **UTF-16 code units** (an emoji is 2). To
align comment ranges, `Canonical.Text` works in those units:

```elixir
flatten_text(node_map) :: String.t()          # concatenate descendant text (no separators)
utf16_length(string)   :: non_neg_integer()
utf16_slice(string, from, to) :: String.t()    # END-offset semantics, surrogate-safe
```

`flatten_text/1` inserts no separators between blocks, so offsets line up exactly
with what the frontend sees. `utf16_slice/3` clamps out-of-range offsets and, if a
slice ends mid-surrogate, returns the valid decoded prefix rather than failing.

## Public API

```elixir
# Import a source document → ProseMirror JSON map + metadata.
# Binary input is temp-filed for Pandoc; opts[:source_format] (atom or string)
# sets the Pandoc reader. Canonical opts: :id_generator, :preserve_soft_breaks,
# :on_invalid (:error | :warn), :schema. Everything else is forwarded to Pandoc.
Canonical.import_document(content_or_opts, opts \\ []) ::
  {:ok, %{doc: map(), meta: map(), warnings: [term()]}} | {:error, term()}
#   meta => %{"title" => string | nil, "word_count" => integer, "source_format" => term}

Canonical.validate(doc_or_node, schema \\ default)  :: :ok | {:error, [%{path, message}]}
Canonical.to_pm_json(node)  :: map()
Canonical.from_pm_json(map) :: %Canonical.Node{}
Canonical.flatten_text(node_map) / utf16_length/1 / utf16_slice/3
Canonical.ingest(input_or_opts, opts \\ [])  :: {:ok, %Node{}, warnings}   # struct-returning variant
```

**Invariant:** `from_pm_json(to_pm_json(node)) == node` for canonical-shaped nodes.

## Consuming it from an app (e.g. perfect_paper)

The boundary is map-based, so a host app stores the doc as JSONB and never sees
panpipe structs:

```elixir
{:ok, %{doc: doc, meta: meta}} = Canonical.import_document(bytes, source_format: "docx")
:ok = Canonical.validate(doc)                       # gate before persisting
# store `doc` (jsonb) + `meta`; render with your own components reading attrs["id"];
# anchor comments with Canonical.flatten_text/utf16_length/utf16_slice.
```

Tip: keep your own `Importer` behaviour with a `Stub` adapter for hermetic tests
so the suite doesn't shell out to Pandoc; point the real adapter at
`Canonical.import_document/2`.

## Scope / non-goals

Import + canonical model + validation + PM JSON + text helpers are in scope. Export
(canonical → other formats) lives in `Canonical.Export`. A live CRDT engine and an
actual editor are out of scope here (the model is shaped to support them later).
