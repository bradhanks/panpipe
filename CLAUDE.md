# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

An Elixir wrapper around the [Pandoc](https://pandoc.org/) CLI. It provides three things: a thin wrapper over the `pandoc` command, an Elixir-struct representation of the Pandoc AST, and tools to traverse/transform that AST (i.e. write Pandoc filters in Elixir).

**Hard requirement:** the `pandoc` binary must be installed and on `PATH`. The library shells out to it for every conversion, and parts of compilation read its output (see "Pandoc capability files" below). Tests will fail without it, and pin to specific Pandoc output behavior (test fixtures were last aligned to Pandoc 3.7.x).

## Commands

```sh
mix deps.get                 # fetch deps
mix compile                  # note: runs the :protocol_ex compiler (see mix.exs) in addition to the standard ones
mix test                     # run all tests
mix test test/panpipe/ast_node_test.exs            # single file
mix test test/panpipe/ast_node_test.exs:42         # single test at line 42
mix format                   # apply formatting
mix format --check-formatted # CI gate
mix deps.unlock --check-unused # CI gate
mix pandoc.update_infos      # regenerate priv/pandoc/info/*.txt from the locally installed pandoc
```

CI matrix runs Elixir 1.14–1.19 / OTP 24–28. `mix.exs` declares `elixir: "~> 1.9"`.

## Architecture

The codebase is two cooperating halves joined by Pandoc's JSON AST as the wire format.

### 1. The Pandoc CLI bridge — `lib/panpipe/pandoc/`
- `Panpipe.Pandoc.call/2` (`pandoc.ex`) builds CLI args from a keyword list and pipes input/output through the binary via `Exile`. Long-form pandoc flags map to underscored keys (`pdf_engine: :xelatex`); boolean flags are passed as `opt: true`. Input/output formats accept `{:format, [extensions]}` or `{:format, %{enable: ..., disable: ...}}` tuples.
- A small set of keys (`@panpipe_options` in `pandoc.ex`) are consumed by the wrapper itself and stripped before building the pandoc command (e.g. `input`, `remove_trailing_newline`).
- `Panpipe.Pandoc.Conversion` (`conversion.ex`) is a protocol for converting either a raw string **or** any AST node to a target format. The AST-node implementation is generated inside the `Panpipe.AST.Node.__using__` macro: it wraps the node in a `Document` fragment, serializes to Pandoc JSON, and feeds it back to `pandoc --from json`.

### 2. The AST layer — `lib/panpipe/ast/`
- `Panpipe.AST.Node` (`node.ex`) is the behaviour every node implements **and** the `use Panpipe.AST.Node, type: :block|:inline, fields: [...]` macro that generates each node struct. The macro injects: the `defstruct` (block nodes get a `children` field; all nodes get `parent`), `block?/0` / `inline?/0` / `children/1`, an `Enumerable` impl (pre-order traversal), the `Conversion` impl, and a default `transform/2`.
- `Panpipe.AST.*` nodes themselves live in `lib/panpipe/ast/nodes.ex` (one `defmodule` per Pandoc element: `Para`, `Header`, `Table`, `Emph`, `Str`, …). Each defines `to_pandoc/1` (emit Pandoc JSON map) and `to_panpipe/1` (ingest).
- **Two directions, two mechanisms — don't confuse them:**
  - **Panpipe → Pandoc:** `to_pandoc/1`, a plain function on each node module, dispatched via `Panpipe.AST.Node.to_pandoc/1`.
  - **Pandoc → Panpipe:** `Panpipe.Pandoc.AST.Node`, a **ProtocolEx** protocol (`defprotocol_ex`, top of `nodes.ex`) with a `to_panpipe/1` clause per node. ProtocolEx (not a standard Elixir protocol) is why `mix.exs` adds the `:protocol_ex` compiler. The fallback clause is kept inside the protocol definition itself to avoid ProtocolEx compile-ordering issues — preserve that arrangement when editing.
- `parent` is `nil` on freshly built/parsed nodes. It is populated lazily — only one level up, not to the root — during `Enumerable` traversal and within `transform/2`, so transformations can pattern-match on a node's immediate parent.
- `transform/2` (in `node.ex`) walks pre-order; the callback returns `nil` to leave a node unchanged, a replacement node, a list of nodes (splice), `[]`/`Panpipe.AST.Null` to delete, or `{:halt, replacement}` to stop recursing into the replacement.
- `Panpipe.Document` (`document.ex`) is the root wrapper (`children` + `meta`); `Panpipe.Document.fragment/1` wraps a bare node so it can be round-tripped through pandoc.

### 3. Public surface — `lib/panpipe.ex`
Delegates: `pandoc/2` + `pandoc!/2` (raw conversion), `ast/2` + `ast!/2` (parse to `Panpipe.Document`), `ast_fragment/2` (parse and unwrap to a single node), `transform/2`, and auto-generated `to_<format>/2` helpers for every Pandoc output format.

### Pandoc capability files — `priv/pandoc/info/`
`*.txt` lists of supported input formats, extensions, highlight languages/styles are read at runtime (`Panpipe.Pandoc.Info`) to validate/expose pandoc's feature set. They are checked-in snapshots; regenerate with `mix pandoc.update_infos` when targeting a new pandoc version.

## Adding or changing an AST node

A node is only complete when **both** conversion directions exist. In `lib/panpipe/ast/nodes.ex`: add a `defmodule` that does `use Panpipe.AST.Node, type: ..., fields: ...`, implement `to_pandoc/1` on it, and add a `to_panpipe/1` clause to the `Panpipe.Pandoc.AST.Node` ProtocolEx protocol. Helper structs that aren't real Pandoc elements (e.g. `Attr`, `ListAttributes`, `ColSpec`) are plain `defstruct`s with their own `from_pandoc`/`to_pandoc` and are invoked manually by the nodes that contain them.

## Testing notes

`test/test_helper.exs` auto-requires every file in `test/support/` (e.g. `generators_helper.exs` for StreamData property tests). Fixtures live in `test/fixtures/`; conversion tests compare against real pandoc output, so a pandoc version change can legitimately break them.
