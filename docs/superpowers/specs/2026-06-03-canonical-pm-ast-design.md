# Canonical SSoT: ProseMirror-shaped AST with Pandoc Import — Design

**Date:** 2026-06-03
**Status:** Approved (design); ready for implementation planning
**Phase:** 1 of N (ingestion + canonical model)

## Summary

Build a **canonical, source-of-truth document model** on top of the existing
`panpipe` codebase. The canonical model is a **ProseMirror-shaped, typed,
schema-validated AST** that serializes to **literal ProseMirror document JSON**.
Pandoc (via panpipe) is demoted to the **import engine**: it feeds an untouched
intermediate representation that we transform into the canonical model.

This phase delivers the **transformation core only** — a pure, persistence-free
pipeline from document input to validated ProseMirror JSON.

### Goals

- **Immediate:** a canonical at-rest representation (PM JSON + stable IDs) that
  many source formats can be imported into via Pandoc.
- **Medium-term (not built here, but designed for):** the same model becomes the
  live document behind a collaborative editor; hence CRDT-readiness is baked in
  now (stable per-node identity, merge-friendly structure).

### Non-goals (Phase 1)

- **No export** (canonical → Pandoc → other formats). Separate later spec.
- **No CRDT engine.** Only stable IDs + merge-friendly structure; engine choice
  (Yjs/Automerge/custom) deferred to the editor phase.
- **No persistence/editor layer.** The core emits a validated PM JSON map; where
  and how it is stored is entirely the host application's concern. No Ecto,
  Postgrex, Oban, Repo, or migrations are introduced.
- **No full ProseMirror content-expression grammar parity.** Common forms only
  (see Validation).
- **No rebrand churn now.** Built under a placeholder `Canonical.*` namespace;
  renaming to the product namespace is a later mechanical step.

## Key decisions (locked during brainstorming)

| # | Decision |
|---|----------|
| 1 | Phase 1 = at-rest storage/interchange SSoT; medium-term = collaborative-editor backend. |
| 2 | Canonical form = **literal ProseMirror JSON**, schema-validated, loadable by a real PM editor with no adapter. |
| 3 | Schema = **custom**, rich enough to cover the chosen Pandoc feature set. |
| 4 | CRDT = **agnostic**; stable per-node IDs + merge-friendly structure; engine deferred. |
| 5 | Phase 1 = **import + canonical↔PM-JSON** only; export deferred. |
| 6 | Repo = **hard fork / rebrand** eventually; name TBD; build under placeholder `Canonical.*` now, rename later. |
| 7 | **IDs + PM-conformance live on the new canonical AST**; `panpipe` stays an untouched import IR. |
| 8 | Unmappable constructs → **typed escape nodes** (lossless). |
| 9 | Representation = **uniform `%Node{}` struct + declarative `Schema`-as-data** (mirrors ProseMirror's own Node/Schema split). |
| 10 | Stable IDs on **block + atomic nodes only**, as `attrs["id"]`; text nodes carry none (PM/CRDT track text positionally). |
| 11 | Persistence is **agnostic** — core emits a validated PM JSON map; no Spec 2 persistence commitment. |

## Architecture

A unidirectional pipeline. Each stage is a set of pure, independently testable
functions:

```
input/opts
  │  Panpipe.ast!/2            (REUSED, untouched)
  ▼
%Panpipe.Document{}            import IR — nested, Pandoc-shaped (inline = nested nodes)
  │  Canonical.Import.Block / .Inline
  ▼
%Canonical.Node{} tree         canonical, ProseMirror-shaped (inline = flat text + marks); no IDs yet
  │  Canonical.Id (mint/preserve + de-dupe)
  ▼
%Canonical.Node{} tree         + attrs["id"] on block/atomic nodes
  │  Canonical.Schema.Validator
  ▼
:ok | {:error, violations}     final gate (default hard-fail)
  │  Canonical.PM.to_json/1
  ▼
ProseMirror JSON map           literal {type, attrs, content, marks, text}
```

### Module layout

| Module | Responsibility |
|--------|----------------|
| `Panpipe.*` | **Reused, untouched.** Import IR. `Panpipe.ast/2` parses source → nested Pandoc-shaped struct tree. |
| `Canonical.Node` | `%Node{type, attrs, content, marks, text}` struct; `%Mark{type, attrs}`; helpers `block?/1`, `inline?/1`, `text?/1`, tree walk. |
| `Canonical.Schema` | `%Schema{nodes, marks, top_node}` + `NodeSpec`/`MarkSpec` shapes (content expr, group, inline?, atom?, attrs, allowed marks). Pure data. |
| `Canonical.Schema.Pandoc` | The concrete custom schema instance covering the Pandoc feature set. |
| `Canonical.Schema.Validator` | Walks a `%Node{}` tree against a `%Schema{}` → `:ok \| {:error, [violation]}`. |
| `Canonical.Import` | Orchestrator + public entry: IR → map → mint IDs → validate. |
| `Canonical.Import.Block` | Block-element mapping. |
| `Canonical.Import.Inline` | Inline-flattening engine (nested inline IR → flat text + marks). |
| `Canonical.Id` | Pluggable stable-ID generator; preservation + de-dupe logic. |
| `Canonical.PM` | `to_json/1` and `from_json/1` — `%Node{}` ↔ literal ProseMirror JSON (Jason). |

### Public API (placeholder namespace)

```elixir
Canonical.import(input_or_opts, opts \\ [])  :: {:ok, doc :: %Node{}, warnings :: [warning]} | {:error, term}
Canonical.from_panpipe(%Panpipe.Document{})  :: {:ok, doc, warnings} | {:error, term}
Canonical.to_pm_json(doc :: %Node{})         :: map
Canonical.from_pm_json(map)                  :: %Node{}
Canonical.validate(doc, schema \\ Canonical.Schema.Pandoc.schema()) :: :ok | {:error, [violation]}
```

`opts` includes at least: `:id_generator` (pluggable, for deterministic tests),
`:preserve_soft_breaks` (default `false`), `:on_invalid` (`:error` default |
`:warn`).

## Data model

One struct, mirroring ProseMirror's real shape:

```elixir
%Canonical.Node{
  type:    "paragraph",      # matches a schema node name
  attrs:   %{},              # includes "id" on id-bearing nodes
  content: [%Node{}, ...],   # [] for leaf/atom nodes
  marks:   [%Mark{}],        # only populated on inline nodes; ordered by schema rank
  text:    nil               # set only when type == "text"
}

%Canonical.Mark{type: "strong", attrs: %{}}
```

## Schema (custom, covers the Pandoc feature set)

**Block nodes:** `doc`, `paragraph`, `heading` (attr: `level`), `blockquote`,
`code_block` (attrs: `language`, plus preserved attrs), `bullet_list`,
`ordered_list` (attrs: `start`, `style`, `delimiter`), `list_item`,
`horizontal_rule`, `table`, `table_row`, `table_cell`, `table_header`
(+ caption modeling), `definition_list`, `def_term`, `def_desc`, `div`
(attrs: `classes`, key-values), `line_block`, plus escape nodes
`raw_block` (attrs: `format`, `text`) and `unsupported_block`
(attr: original Pandoc JSON).

**Inline nodes:** `text`, `image` (attrs: `src`, `alt`, `title`), `hard_break`,
`math` (attrs: `mode` = inline|display, `tex`), `footnote` (content), plus escape
`raw_inline` (attrs: `format`, `text`) and `unsupported_inline`
(attr: original Pandoc JSON).

**Marks:** `em` (Pandoc `Emph`), `strong`, `code` (Pandoc inline `Code`),
`link` (attrs: `href`, `title`), `strikethrough`, `superscript`, `subscript`,
`smallcaps`, `underline`, `span` (attrs: `id`, `classes`, key-values — see Span
mapping below).

### Resolved modeling details

- **Tables.** `table` content = `table_caption? table_row+`. The Pandoc caption
  (which is *blocks*, possibly formatted) maps to a child **`table_caption`**
  node holding mapped block/inline content — **not** a flattened string attr, to
  stay lossless. Cells (`table_cell`/`table_header`) carry an `align` attr
  (`left|center|right|default`). Column-width / detailed colspec calculations are
  **deferred** for Phase 1 but the raw colspec is preserved on the `table` node's
  attrs (e.g. `attrs["colspec"]`) so nothing is lost.
- **Definition lists.** `definition_list = (def_term def_desc+)+` — note `+` on
  `def_desc`, because Pandoc's `DefinitionList` (`[([Inline], [[Block]])]`)
  permits **multiple definitions per term**. `def_term = inline*`;
  `def_desc = block+`.

**ID-bearing nodes:** all block + atomic nodes carry `attrs["id"]`; `text` nodes
do not (ProseMirror text nodes cannot hold attrs/ids; text identity is tracked
positionally by the CRDT). This is exactly what PM "unique node id" plugins do
and is the correct granularity for the future merge story.

## Import pipeline

### Block mapping (`Canonical.Import.Block`)

Mostly 1:1: `Para`/`Plain`→`paragraph`, `Header`→`heading`,
`BlockQuote`→`blockquote`, `CodeBlock`→`code_block`,
`BulletList`→`bullet_list` (items→`list_item`), `OrderedList`→`ordered_list`,
`Table`→`table`/`table_row`/`table_cell`+`table_header`,
`DefinitionList`→`definition_list`/`def_term`/`def_desc`, `Div`→`div`,
`RawBlock`→`raw_block`, `HorizontalRule`→`horizontal_rule`,
`LineBlock`→`line_block`. Block children recurse; inline-bearing blocks hand
their children to the Inline engine. Anything unrecognized → `unsupported_block`
carrying the original Pandoc JSON (+ warning).

### Inline flattening (`Canonical.Import.Inline`) — the core transform

Recursive descent carrying an accumulated mark-set:

```
flatten(inline_irs, active_marks) -> [%Node{}]   # then coalesce + order marks
```

- **Mark-producing wrappers** (have children): `Emph→em`, `Strong→strong`,
  `Strikeout→strikethrough`, `Superscript→superscript`, `Subscript→subscript`,
  `SmallCaps→smallcaps`, `Underline→underline`, `Link→link` (href/title).
  Recurse into children with `active_marks + this_mark`.
- **`Span`** (attrs + children): map to the `span` **mark** carrying
  `id`/`classes`/key-values in its attrs, recursing into children with that mark
  added. Fall back to `unsupported_inline` only if a span genuinely cannot be
  represented as a mark.
- **Inline `Code`** (leaf string, not children): emit a `text` node with
  `active_marks + code`.
- **Leaf text:** `Str`→`text`(string); `Space`→`text " "`; `SoftBreak`→`text " "`
  by default, or preserved as `"\n"` when `preserve_soft_breaks: true`;
  `LineBreak`→`hard_break` node.
- **Atomic inline nodes:** `Image`→`image`, `Math`→`math`,
  `RawInline`→`raw_inline`.
- **Inline node with block content:** `Note`→`footnote`, whose content is the
  footnote's blocks mapped via the Block stage (not atomic).
- **Mark ordering:** before output, the marks on each node are ordered by their
  **rank in the schema's mark spec** (matching ProseMirror's `Mark.addToSet`
  convention), with the mark type name as a stable tiebreaker. Deterministic and
  PM-idiomatic.
- **Coalescing:** adjacent `text` nodes with **equal mark-sets** (type + attrs)
  are merged into one, producing PM-idiomatic `"text"` runs rather than
  fragmented characters.

### ID minting (`Canonical.Id`)

Post-order walk over the canonical tree assigning `attrs["id"]` to every
id-bearing node type:

1. **Preserve** the IR's parsed identifier when present and non-empty (Pandoc
   parses `{#id}` on `Header`, `Div`, `CodeBlock`, `Span`, etc. via its `Attr`).
2. **De-dupe:** preserved IDs are not guaranteed unique (copy-paste duplicates
   are common) or valid. If a preserved ID collides with one already seen, the
   later node receives a freshly generated ID and a warning is emitted.
3. **Generate** a collision-resistant random ID (nanoid-style) when no usable
   identifier exists.

The generator is injected via `opts[:id_generator]` so tests can use a
deterministic sequence.

## Validation (`Canonical.Schema.Validator`)

Pre-order walk collecting violations with a path (e.g.
`doc/content[2]/content[0]`). Per node:

1. `type` exists in the schema.
2. **Content** satisfies the node's content expression. Phase-1 supported forms:
   `name`, `group`, `*`, `+`, `?`, sequences, and `(a | b)` alternation — enough
   to enforce rules like `table_row = (table_cell | table_header)+`,
   `bullet_list = list_item+`, `doc = block+`. Content expressions are parsed via
   **`nimble_parsec`** into a matcher. Full PM regex-grammar parity is a later
   enhancement.
3. `marks` on the node are all in the node's allowed-marks set; marks only on
   inline nodes.
4. Required `attrs` present; defaults filled from the spec.
5. `text` set iff `type == "text"`; text only where inline content is permitted.

Returns `:ok | {:error, [violation]}`. `Canonical.import/2` runs validation as
the final gate. Default `on_invalid: :error` (hard-fail — this is an SSoT);
`:warn` returns the doc with violations as warnings.

## PM JSON serialization (`Canonical.PM`)

- `to_json/1`: `text` node → `%{"type" => "text", "text" => …, "marks" => […]}`
  (omit `marks` when empty); other nodes →
  `%{"type" => …, "attrs" => …, "content" => […], "marks" => …}`, omitting empty
  `attrs`/`content`/`marks` for clean, idiomatic PM output. Marks →
  `%{"type" => …, "attrs" => …}`.
- `from_json/1`: inverse; tolerant of omitted optional keys; fills attr defaults
  from the schema.
- **Invariant (property-tested):** `from_json(to_json(node)) == node`.

## Testing strategy (TDD)

- **Inline engine units:** nested marks → coalesced `text`+marks;
  `link`/`code`/`image`/`hard_break`/`math`/`footnote`; `Span`→`span` mark;
  mark-ordering determinism; soft-break config.
- **ID units:** preserve Pandoc `Attr` id; mint when absent; **collision
  de-dupe**; deterministic generator injection.
- **Block mapping units:** one per element family.
- **Golden fixtures:** markdown → canonical (deterministic IDs) and → PM JSON;
  checked-in expected files.
- **Property tests:** (a) every fixture validates against the schema;
  (b) `from_json ∘ to_json == identity`; (c) re-import structural idempotence
  (IDs stripped).
- **Lossless/escape:** raw HTML block + unknown construct → escape nodes,
  warnings emitted.
- **Validator:** positive **and** negative (e.g. `table_row` containing a
  `paragraph` is rejected; a disallowed mark is rejected).

## Dependencies

- `nimble_parsec` — content-expression parsing.
- **No new ID dependency.** `Canonical.Id` is a hand-rolled, zero-dep generator
  using `:crypto.strong_rand_bytes/1` over a 64-char URL-safe alphabet with
  **6-bit masking** (`byte &&& 63`) — the nanoid technique, which is bias-free
  (a naive `rem(byte, 62)` over 0–255 would skew the character distribution).
  Default length 12; generator is injectable via `opts[:id_generator]`.
- Existing: `jason` (already a dep), `panpipe` modules (in-repo).

## Rebrand handling (deferred, off critical path)

Build under `Canonical.*` alongside `Panpipe.*`. The eventual rebrand
(find/replace to the product namespace, `mix.exs` app rename, pruning the
deferred `to_<format>` export helpers) is its own commit once the product name is
chosen. Not on the Phase-1 critical path.

## Resolved during review

- **ID format/generator:** hand-rolled zero-dep `:crypto` + 6-bit masking,
  length 12 (see Dependencies).
- **Table/caption:** `table_caption` child node (lossless); cell `align` attr;
  colspec preserved on table attrs, width calc deferred (see Resolved modeling
  details).
- **Definition lists:** `(def_term def_desc+)+` (see Resolved modeling details).
- **No UTF-16 / character-offset tracking** in Phase 1: the canonical form stores
  no positions; text is plain strings and PM positions are derived. (A potential
  concern only in the much-later CRDT/editor phase, and handled by the CRDT there
  — explicitly out of scope here.)

## Open items for the implementation plan

- Exact attr lists per remaining node/mark (finalize during schema
  implementation).
- Choice of nanoid alphabet characters (URL-safe set) — cosmetic.
