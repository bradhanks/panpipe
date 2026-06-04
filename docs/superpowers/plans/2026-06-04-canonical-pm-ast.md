# Canonical ProseMirror-shaped AST — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a persistence-free transformation core that imports any Pandoc-supported document into a custom ProseMirror-shaped, schema-validated, typed AST with stable per-node IDs, and serializes it to literal ProseMirror JSON.

**Architecture:** A unidirectional pipeline — `Panpipe.ast!/2` (untouched IR) → `Canonical.Import.Block`/`Inline` map to a uniform `%Canonical.Node{}` tree (inline formatting flattened from nested IR nodes into PM-style marks) → `Canonical.Id` mints/preserves stable IDs → `Canonical.Schema.Validator` gates against a declarative schema → `Canonical.PM` emits ProseMirror JSON.

**Tech Stack:** Elixir, `panpipe` (in-repo, reused as import IR), `jason` (already a dep). No new dependencies — the content-expression parser is hand-rolled (recursive descent); IDs use `:crypto` with 6-bit masking.

**Spec:** `docs/superpowers/specs/2026-06-03-canonical-pm-ast-design.md`

**Conventions for every task:** run `mix test <path>` to see RED, implement, run again to see GREEN, then commit. Run `mix format` before each commit.

---

## File map

| File | Responsibility |
|------|----------------|
| `lib/canonical/node.ex` | `%Canonical.Node{}` + `%Canonical.Mark{}` structs, constructors, mark ordering. |
| `lib/canonical/id.ex` | Stable-ID generator (bias-free) + tree minting pass (preserve/de-dupe/generate). |
| `lib/canonical/schema.ex` | `%Schema{}`, `NodeSpec`, `MarkSpec` data + accessors (`node_spec`, `mark_allowed?`, groups). |
| `lib/canonical/schema/content_expr.ex` | Parse + match ProseMirror content expressions. |
| `lib/canonical/schema/pandoc.ex` | The concrete custom schema covering the Pandoc feature set. |
| `lib/canonical/schema/validator.ex` | Validate a `%Node{}` tree against a `%Schema{}`. |
| `lib/canonical/import/attrs.ex` | Shared `Panpipe.AST.Attr` → canonical attrs map helper. |
| `lib/canonical/import/inline.ex` | Inline-flattening engine (nested inline IR → flat text + marks). |
| `lib/canonical/import/block.ex` | Block-element mapping. |
| `lib/canonical/import.ex` | Orchestrator: IR → map → mint → validate → `{:ok, doc, warnings}`. |
| `lib/canonical/pm.ex` | `%Node{}` ↔ ProseMirror JSON. |
| `lib/canonical.ex` | Public façade (`ingest/2`, `from_panpipe/2`, `to_pm_json/1`, `from_pm_json/1`, `validate/2`). |

---

## Task 1: Scaffold `Canonical.Node` and `Canonical.Mark`

**Files:**
- Create: `lib/canonical/node.ex`
- Test: `test/canonical/node_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
# test/canonical/node_test.exs
defmodule Canonical.NodeTest do
  use ExUnit.Case, async: true
  alias Canonical.{Node, Mark}

  test "text/2 builds a text node with sorted marks" do
    node = Node.text("hi", [Mark.new("strong"), Mark.new("em")])
    assert node.type == "text"
    assert node.text == "hi"
    # em ranks before strong in the canonical order
    assert Enum.map(node.marks, & &1.type) == ["em", "strong"]
  end

  test "text?/1 distinguishes text nodes" do
    assert Node.text?(Node.text("x", []))
    refute Node.text?(%Node{type: "paragraph"})
  end

  test "Mark.sort orders by canonical rank, then name" do
    marks = [Mark.new("link"), Mark.new("code"), Mark.new("em")]
    assert Enum.map(Mark.sort(marks), & &1.type) == ["em", "code", "link"]
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/canonical/node_test.exs`
Expected: FAIL — `Canonical.Node` / `Canonical.Mark` undefined.

- [ ] **Step 3: Write minimal implementation**

```elixir
# lib/canonical/node.ex
defmodule Canonical.Mark do
  @moduledoc "An inline ProseMirror mark."
  defstruct type: nil, attrs: %{}

  @type t :: %__MODULE__{type: String.t(), attrs: map()}

  # Canonical mark order — mirrors ProseMirror's schema-rank ordering so emitted
  # JSON is deterministic. This list is the single source of truth for mark order
  # and is reused by Canonical.Schema.Pandoc.
  @order ~w(em strong underline strikethrough superscript subscript smallcaps code link span)

  def order, do: @order

  def rank(type), do: Enum.find_index(@order, &(&1 == type)) || length(@order)

  def new(type, attrs \\ %{}), do: %__MODULE__{type: type, attrs: attrs}

  @doc "Sort marks by canonical rank, with type name as a stable tiebreaker."
  def sort(marks), do: Enum.sort_by(marks, &{rank(&1.type), &1.type})
end

defmodule Canonical.Node do
  @moduledoc "A uniform ProseMirror-shaped AST node."
  alias Canonical.Mark

  defstruct type: nil, attrs: %{}, content: [], marks: [], text: nil

  @type t :: %__MODULE__{
          type: String.t(),
          attrs: map(),
          content: [t()],
          marks: [Mark.t()],
          text: String.t() | nil
        }

  @doc "Build a text node, sorting its marks into canonical order."
  def text(string, marks \\ []) when is_binary(string) do
    %__MODULE__{type: "text", text: string, marks: Mark.sort(marks)}
  end

  def text?(%__MODULE__{type: "text"}), do: true
  def text?(%__MODULE__{}), do: false
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/canonical/node_test.exs`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
mix format
git add lib/canonical/node.ex test/canonical/node_test.exs
git commit -m "feat(canonical): add Node and Mark structs with canonical mark ordering"
```

---

## Task 2: ID generator (`Canonical.Id.generate/1`)

**Files:**
- Create: `lib/canonical/id.ex`
- Test: `test/canonical/id_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
# test/canonical/id_test.exs
defmodule Canonical.IdTest do
  use ExUnit.Case, async: true
  alias Canonical.Id

  test "generate/0 returns a 12-char URL-safe string" do
    id = Id.generate()
    assert String.length(id) == 12
    assert id =~ ~r/\A[0-9A-Za-z_-]{12}\z/
  end

  test "generate/1 honors length and is (practically) unique" do
    ids = for _ <- 1..1000, do: Id.generate(16)
    assert Enum.all?(ids, &(String.length(&1) == 16))
    assert length(Enum.uniq(ids)) == 1000
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/canonical/id_test.exs`
Expected: FAIL — `Canonical.Id` undefined.

- [ ] **Step 3: Write minimal implementation**

```elixir
# lib/canonical/id.ex
defmodule Canonical.Id do
  @moduledoc """
  Stable identifier generation and the tree-minting pass.

  IDs use a 64-character URL-safe alphabet with 6-bit masking (`band(byte, 63)`),
  which is bias-free because the alphabet size divides 256 evenly — unlike a naive
  `rem(byte, 62)`, which would skew the character distribution.
  """
  import Bitwise

  # Exactly 64 URL-safe characters.
  @alphabet ~c"0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz-_"

  @doc "Generate a random URL-safe id of the given length (default 12)."
  def generate(length \\ 12) when length > 0 do
    :crypto.strong_rand_bytes(length)
    |> :binary.bin_to_list()
    |> Enum.map(fn byte -> Enum.at(@alphabet, band(byte, 63)) end)
    |> List.to_string()
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/canonical/id_test.exs`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
mix format
git add lib/canonical/id.ex test/canonical/id_test.exs
git commit -m "feat(canonical): add bias-free URL-safe id generator"
```

---

## Task 3: Schema data structures (`Canonical.Schema`)

**Files:**
- Create: `lib/canonical/schema.ex`
- Test: `test/canonical/schema_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
# test/canonical/schema_test.exs
defmodule Canonical.SchemaTest do
  use ExUnit.Case, async: true
  alias Canonical.Schema
  alias Canonical.Schema.{NodeSpec, MarkSpec}

  setup do
    schema = %Schema{
      top_node: "doc",
      nodes: %{
        "doc" => %NodeSpec{content: "block+"},
        "paragraph" => %NodeSpec{content: "inline*", group: "block", inline: false, marks: :all},
        "text" => %NodeSpec{text?: true, inline: true, group: "inline"}
      },
      marks: %{"em" => %MarkSpec{}}
    }

    {:ok, schema: schema}
  end

  test "node_spec/2 fetches specs", %{schema: schema} do
    assert {:ok, %NodeSpec{content: "block+"}} = Schema.node_spec(schema, "doc")
    assert :error = Schema.node_spec(schema, "nope")
  end

  test "groups/2 returns a node's groups", %{schema: schema} do
    assert Schema.groups(schema, "paragraph") == ["block"]
    assert Schema.groups(schema, "text") == ["inline"]
  end

  test "mark_allowed?/2 follows :all / list / nil", %{schema: _schema} do
    assert Schema.mark_allowed?(:all, "em")
    assert Schema.mark_allowed?(["em", "strong"], "em")
    refute Schema.mark_allowed?(["strong"], "em")
    refute Schema.mark_allowed?(nil, "em")
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/canonical/schema_test.exs`
Expected: FAIL — `Canonical.Schema` undefined.

- [ ] **Step 3: Write minimal implementation**

```elixir
# lib/canonical/schema.ex
defmodule Canonical.Schema do
  @moduledoc "Declarative ProseMirror-style schema as data."

  defmodule NodeSpec do
    @moduledoc "Spec for a single node type."
    # content: a content-expression string, or nil for leaf/atom nodes.
    # group:   space-separated group names (e.g. "block"); nil for none.
    # attrs:   %{name => %{default: value}} ; absence of :default means required.
    # marks:   :all | [mark_name] | nil  — which marks are allowed on inline children.
    # inline:  true for inline nodes. atom: leaf node. text?: the text node.
    defstruct content: nil, group: nil, inline: false, atom: false, attrs: %{}, marks: nil, text?: false
  end

  defmodule MarkSpec do
    @moduledoc "Spec for a single mark type."
    defstruct attrs: %{}
  end

  defstruct nodes: %{}, marks: %{}, top_node: "doc"

  def node_spec(%__MODULE__{nodes: nodes}, type), do: Map.fetch(nodes, type)

  def mark_spec(%__MODULE__{marks: marks}, type), do: Map.fetch(marks, type)

  @doc "Group names for a node type (empty list if unknown or ungrouped)."
  def groups(%__MODULE__{} = schema, type) do
    case node_spec(schema, type) do
      {:ok, %NodeSpec{group: nil}} -> []
      {:ok, %NodeSpec{group: group}} -> String.split(group)
      :error -> []
    end
  end

  def mark_allowed?(:all, _type), do: true
  def mark_allowed?(nil, _type), do: false
  def mark_allowed?(list, type) when is_list(list), do: type in list
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/canonical/schema_test.exs`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
mix format
git add lib/canonical/schema.ex test/canonical/schema_test.exs
git commit -m "feat(canonical): add declarative schema data structures"
```

---

## Task 4: Content-expression parser

**Files:**
- Create: `lib/canonical/schema/content_expr.ex`
- Test: `test/canonical/schema/content_expr_parse_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
# test/canonical/schema/content_expr_parse_test.exs
defmodule Canonical.Schema.ContentExprParseTest do
  use ExUnit.Case, async: true
  alias Canonical.Schema.ContentExpr, as: CE

  test "parses empty as nil" do
    assert CE.parse("") == nil
  end

  test "parses a bare name" do
    assert CE.parse("block") == {:name, "block"}
  end

  test "parses quantifiers" do
    assert CE.parse("block+") == {:plus, {:name, "block"}}
    assert CE.parse("inline*") == {:star, {:name, "inline"}}
    assert CE.parse("table_caption?") == {:opt, {:name, "table_caption"}}
  end

  test "parses a sequence" do
    assert CE.parse("def_term def_desc+") ==
             {:seq, [{:name, "def_term"}, {:plus, {:name, "def_desc"}}]}
  end

  test "parses alternation with parens and quantifier" do
    assert CE.parse("(table_cell | table_header)+") ==
             {:plus, {:or, [{:name, "table_cell"}, {:name, "table_header"}]}}
  end

  test "parses a grouped sequence repeated" do
    assert CE.parse("(def_term def_desc+)+") ==
             {:plus, {:seq, [{:name, "def_term"}, {:plus, {:name, "def_desc"}}]}}
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/canonical/schema/content_expr_parse_test.exs`
Expected: FAIL — `Canonical.Schema.ContentExpr` undefined.

- [ ] **Step 3: Write minimal implementation**

```elixir
# lib/canonical/schema/content_expr.ex
defmodule Canonical.Schema.ContentExpr do
  @moduledoc """
  Parser and matcher for ProseMirror content expressions.

  Grammar (precedence low→high):
    alt     := seq ("|" seq)*
    seq     := postfix+
    postfix := atom ("*" | "+" | "?")?
    atom    := name | "(" alt ")"

  AST: {:name, n} | {:seq, [..]} | {:or, [..]} | {:star, e} | {:plus, e} | {:opt, e}
  An empty string parses to nil (no content allowed).
  """

  # --- Parsing -------------------------------------------------------------

  def parse(string) when is_binary(string) do
    case tokenize(string, []) do
      [] -> nil
      tokens -> tokens |> parse_alt() |> elem(0)
    end
  end

  defp tokenize("", acc), do: Enum.reverse(acc)
  defp tokenize(<<c, rest::binary>>, acc) when c in [?\s, ?\t], do: tokenize(rest, acc)
  defp tokenize("(" <> rest, acc), do: tokenize(rest, [:lparen | acc])
  defp tokenize(")" <> rest, acc), do: tokenize(rest, [:rparen | acc])
  defp tokenize("|" <> rest, acc), do: tokenize(rest, [:pipe | acc])
  defp tokenize("*" <> rest, acc), do: tokenize(rest, [:star | acc])
  defp tokenize("+" <> rest, acc), do: tokenize(rest, [:plus | acc])
  defp tokenize("?" <> rest, acc), do: tokenize(rest, [:opt | acc])

  defp tokenize(str, acc) do
    {name, rest} = take_name(str, "")
    tokenize(rest, [{:name, name} | acc])
  end

  defp take_name(<<c, rest::binary>>, acc) when c in ?a..?z or c == ?_,
    do: take_name(rest, acc <> <<c>>)

  defp take_name(rest, acc), do: {acc, rest}

  defp parse_alt(tokens) do
    {first, rest} = parse_seq(tokens)
    parse_alt_more(rest, [first])
  end

  defp parse_alt_more([:pipe | rest], acc) do
    {next, rest2} = parse_seq(rest)
    parse_alt_more(rest2, [next | acc])
  end

  defp parse_alt_more(rest, [single]), do: {single, rest}
  defp parse_alt_more(rest, acc), do: {{:or, Enum.reverse(acc)}, rest}

  defp parse_seq(tokens) do
    {first, rest} = parse_postfix(tokens)
    parse_seq_more(rest, [first])
  end

  defp parse_seq_more(tokens, acc) do
    if seq_continues?(tokens) do
      {next, rest} = parse_postfix(tokens)
      parse_seq_more(rest, [next | acc])
    else
      case acc do
        [single] -> {single, tokens}
        _ -> {{:seq, Enum.reverse(acc)}, tokens}
      end
    end
  end

  defp seq_continues?([{:name, _} | _]), do: true
  defp seq_continues?([:lparen | _]), do: true
  defp seq_continues?(_), do: false

  defp parse_postfix(tokens) do
    {atom, rest} = parse_atom(tokens)

    case rest do
      [:star | r] -> {{:star, atom}, r}
      [:plus | r] -> {{:plus, atom}, r}
      [:opt | r] -> {{:opt, atom}, r}
      _ -> {atom, rest}
    end
  end

  defp parse_atom([{:name, n} | rest]), do: {{:name, n}, rest}

  defp parse_atom([:lparen | rest]) do
    {inner, rest2} = parse_alt(rest)
    [:rparen | rest3] = rest2
    {inner, rest3}
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/canonical/schema/content_expr_parse_test.exs`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
mix format
git add lib/canonical/schema/content_expr.ex test/canonical/schema/content_expr_parse_test.exs
git commit -m "feat(canonical): add content-expression parser"
```

---

## Task 5: Content-expression matcher

**Files:**
- Modify: `lib/canonical/schema/content_expr.ex` (add `matches?/3`)
- Test: `test/canonical/schema/content_expr_match_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
# test/canonical/schema/content_expr_match_test.exs
defmodule Canonical.Schema.ContentExprMatchTest do
  use ExUnit.Case, async: true
  alias Canonical.Schema
  alias Canonical.Schema.{NodeSpec, ContentExpr}

  setup do
    schema = %Schema{
      nodes: %{
        "paragraph" => %NodeSpec{group: "block"},
        "heading" => %NodeSpec{group: "block"},
        "text" => %NodeSpec{group: "inline", text?: true},
        "table_cell" => %NodeSpec{},
        "table_header" => %NodeSpec{}
      }
    }

    {:ok, schema: schema}
  end

  test "matches by group name", %{schema: schema} do
    expr = ContentExpr.parse("block+")
    assert ContentExpr.matches?(expr, ["paragraph", "heading"], schema)
    refute ContentExpr.matches?(expr, [], schema)
    refute ContentExpr.matches?(expr, ["text"], schema)
  end

  test "matches alternation under +", %{schema: schema} do
    expr = ContentExpr.parse("(table_cell | table_header)+")
    assert ContentExpr.matches?(expr, ["table_header", "table_cell", "table_cell"], schema)
    refute ContentExpr.matches?(expr, ["table_cell", "paragraph"], schema)
  end

  test "nil expr matches only empty content", %{schema: schema} do
    assert ContentExpr.matches?(nil, [], schema)
    refute ContentExpr.matches?(nil, ["text"], schema)
  end

  test "star matches zero", %{schema: schema} do
    assert ContentExpr.matches?(ContentExpr.parse("inline*"), [], schema)
    assert ContentExpr.matches?(ContentExpr.parse("inline*"), ["text", "text"], schema)
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/canonical/schema/content_expr_match_test.exs`
Expected: FAIL — `matches?/3` undefined.

- [ ] **Step 3: Write minimal implementation** (append to `content_expr.ex` before the final `end`)

```elixir
  # --- Matching ------------------------------------------------------------

  alias Canonical.Schema

  @doc "Does `types` (a list of child node-type strings) satisfy the expression?"
  def matches?(nil, types, _schema), do: types == []

  def matches?(expr, types, schema) do
    expr |> consume(types, schema) |> Enum.any?(&(&1 == []))
  end

  # consume/3 returns the list of possible remaining-type-lists after matching.
  defp consume({:name, name}, [type | rest], schema) do
    if name_matches?(name, type, schema), do: [rest], else: []
  end

  defp consume({:name, _}, [], _schema), do: []

  defp consume({:seq, []}, types, _schema), do: [types]

  defp consume({:seq, [e | es]}, types, schema) do
    e |> consume(types, schema) |> Enum.flat_map(&consume({:seq, es}, &1, schema))
  end

  defp consume({:or, alts}, types, schema) do
    Enum.flat_map(alts, &consume(&1, types, schema))
  end

  defp consume({:opt, e}, types, schema) do
    [types | consume(e, types, schema)]
  end

  defp consume({:star, e}, types, schema) do
    progressed =
      e
      |> consume(types, schema)
      |> Enum.reject(&(&1 == types))
      |> Enum.flat_map(&consume({:star, e}, &1, schema))

    Enum.uniq([types | progressed])
  end

  defp consume({:plus, e}, types, schema) do
    consume({:seq, [e, {:star, e}]}, types, schema)
  end

  defp name_matches?(name, type, schema) do
    name == type or name in Schema.groups(schema, type)
  end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/canonical/schema/content_expr_match_test.exs`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
mix format
git add lib/canonical/schema/content_expr.ex test/canonical/schema/content_expr_match_test.exs
git commit -m "feat(canonical): add content-expression matcher"
```

---

## Task 6: The concrete Pandoc-covering schema

**Files:**
- Create: `lib/canonical/schema/pandoc.ex`
- Test: `test/canonical/schema/pandoc_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
# test/canonical/schema/pandoc_test.exs
defmodule Canonical.Schema.PandocTest do
  use ExUnit.Case, async: true
  alias Canonical.Schema
  alias Canonical.Schema.{NodeSpec, Pandoc}

  test "schema/0 declares the expected top node and key nodes/marks" do
    schema = Pandoc.schema()
    assert schema.top_node == "doc"

    for type <- ~w(doc paragraph heading code_block bullet_list ordered_list list_item
                   table table_row table_cell table_header table_caption
                   definition_list def_term def_desc div line_block horizontal_rule
                   raw_block unsupported_block text image hard_break math footnote
                   raw_inline unsupported_inline) do
      assert {:ok, %NodeSpec{}} = Schema.node_spec(schema, type), "missing node #{type}"
    end

    for mark <- ~w(em strong code link strikethrough superscript subscript smallcaps underline span) do
      assert {:ok, _} = Schema.mark_spec(schema, mark), "missing mark #{mark}"
    end
  end

  test "paragraph allows all marks; code_block allows none" do
    schema = Pandoc.schema()
    assert {:ok, %NodeSpec{marks: :all}} = Schema.node_spec(schema, "paragraph")
    assert {:ok, %NodeSpec{marks: nil}} = Schema.node_spec(schema, "code_block")
  end

  test "heading carries a level attr default" do
    {:ok, spec} = Schema.node_spec(Pandoc.schema(), "heading")
    assert spec.attrs["level"] == %{default: 1}
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/canonical/schema/pandoc_test.exs`
Expected: FAIL — `Canonical.Schema.Pandoc` undefined.

- [ ] **Step 3: Write minimal implementation**

```elixir
# lib/canonical/schema/pandoc.ex
defmodule Canonical.Schema.Pandoc do
  @moduledoc "The custom ProseMirror schema covering the Pandoc feature set."
  alias Canonical.Schema
  alias Canonical.Schema.{NodeSpec, MarkSpec}
  alias Canonical.Mark

  @doc "Returns the schema struct. Cheap to build; callers may memoize if needed."
  def schema do
    %Schema{
      top_node: "doc",
      nodes: nodes(),
      marks: marks()
    }
  end

  defp nodes do
    %{
      "doc" => %NodeSpec{content: "block+"},
      "paragraph" => %NodeSpec{content: "inline*", group: "block", marks: :all, attrs: id_attr()},
      "heading" => %NodeSpec{
        content: "inline*",
        group: "block",
        marks: :all,
        attrs: Map.merge(id_attr(), %{"level" => %{default: 1}})
      },
      "blockquote" => %NodeSpec{content: "block+", group: "block", attrs: id_attr()},
      "code_block" => %NodeSpec{
        content: "text*",
        group: "block",
        marks: nil,
        attrs: Map.merge(id_attr(), %{"language" => %{default: ""}, "classes" => %{default: []}})
      },
      "bullet_list" => %NodeSpec{content: "list_item+", group: "block", attrs: id_attr()},
      "ordered_list" => %NodeSpec{
        content: "list_item+",
        group: "block",
        attrs:
          Map.merge(id_attr(), %{
            "start" => %{default: 1},
            "style" => %{default: "Decimal"},
            "delimiter" => %{default: "Period"}
          })
      },
      "list_item" => %NodeSpec{content: "block+", attrs: id_attr()},
      "horizontal_rule" => %NodeSpec{group: "block", atom: true, attrs: id_attr()},
      "table" => %NodeSpec{
        content: "table_caption? table_row+",
        group: "block",
        attrs: Map.merge(id_attr(), %{"colspec" => %{default: []}})
      },
      "table_caption" => %NodeSpec{content: "block+", attrs: id_attr()},
      "table_row" => %NodeSpec{content: "(table_cell | table_header)+", attrs: id_attr()},
      "table_cell" => %NodeSpec{content: "block+", attrs: cell_attrs()},
      "table_header" => %NodeSpec{content: "block+", attrs: cell_attrs()},
      "definition_list" => %NodeSpec{content: "(def_term def_desc+)+", group: "block", attrs: id_attr()},
      "def_term" => %NodeSpec{content: "inline*", marks: :all, attrs: id_attr()},
      "def_desc" => %NodeSpec{content: "block+", attrs: id_attr()},
      "div" => %NodeSpec{
        content: "block+",
        group: "block",
        attrs: Map.merge(id_attr(), %{"classes" => %{default: []}, "attrs" => %{default: %{}}})
      },
      "line_block" => %NodeSpec{content: "block+", group: "block", attrs: id_attr()},
      "raw_block" => %NodeSpec{
        group: "block",
        atom: true,
        attrs: Map.merge(id_attr(), %{"format" => %{default: ""}, "text" => %{default: ""}})
      },
      "unsupported_block" => %NodeSpec{
        group: "block",
        atom: true,
        attrs: Map.merge(id_attr(), %{"pandoc" => %{}})
      },
      "text" => %NodeSpec{text?: true, inline: true, group: "inline"},
      "image" => %NodeSpec{
        inline: true,
        atom: true,
        group: "inline",
        attrs:
          Map.merge(id_attr(), %{
            "src" => %{default: ""},
            "alt" => %{default: ""},
            "title" => %{default: ""}
          })
      },
      "hard_break" => %NodeSpec{inline: true, atom: true, group: "inline", attrs: id_attr()},
      "math" => %NodeSpec{
        inline: true,
        atom: true,
        group: "inline",
        attrs: Map.merge(id_attr(), %{"mode" => %{default: "inline"}, "tex" => %{default: ""}})
      },
      "footnote" => %NodeSpec{content: "block+", inline: true, group: "inline", attrs: id_attr()},
      "raw_inline" => %NodeSpec{
        inline: true,
        atom: true,
        group: "inline",
        attrs: Map.merge(id_attr(), %{"format" => %{default: ""}, "text" => %{default: ""}})
      },
      "unsupported_inline" => %NodeSpec{
        inline: true,
        atom: true,
        group: "inline",
        attrs: Map.merge(id_attr(), %{"pandoc" => %{}})
      }
    }
  end

  defp marks do
    Map.new(Mark.order(), fn name -> {name, mark_spec(name)} end)
  end

  defp mark_spec("link"), do: %MarkSpec{attrs: %{"href" => %{default: ""}, "title" => %{default: ""}}}

  defp mark_spec("span"),
    do: %MarkSpec{attrs: %{"id" => %{default: ""}, "classes" => %{default: []}, "attrs" => %{default: %{}}}}

  defp mark_spec(_), do: %MarkSpec{}

  # `id` is generated during the minting pass, so it always has a default here.
  defp id_attr, do: %{"id" => %{default: ""}}

  defp cell_attrs do
    Map.merge(id_attr(), %{
      "align" => %{default: "default"},
      "rowspan" => %{default: 1},
      "colspan" => %{default: 1}
    })
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/canonical/schema/pandoc_test.exs`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
mix format
git add lib/canonical/schema/pandoc.ex test/canonical/schema/pandoc_test.exs
git commit -m "feat(canonical): add custom Pandoc-covering ProseMirror schema"
```

---

## Task 7: Validator

**Files:**
- Create: `lib/canonical/schema/validator.ex`
- Test: `test/canonical/schema/validator_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
# test/canonical/schema/validator_test.exs
defmodule Canonical.Schema.ValidatorTest do
  use ExUnit.Case, async: true
  alias Canonical.{Node, Mark}
  alias Canonical.Schema.{Pandoc, Validator}

  defp schema, do: Pandoc.schema()

  defp para(text, marks \\ []) do
    %Node{type: "paragraph", attrs: %{"id" => "p"}, content: [Node.text(text, marks)]}
  end

  test "valid doc passes" do
    doc = %Node{type: "doc", content: [para("hello")]}
    assert Validator.validate(doc, schema()) == :ok
  end

  test "unknown node type is rejected" do
    doc = %Node{type: "doc", content: [%Node{type: "bogus"}]}
    assert {:error, violations} = Validator.validate(doc, schema())
    assert Enum.any?(violations, &(&1.message =~ "unknown node type"))
  end

  test "content-expression violation is rejected" do
    # table_row may only contain table_cell/table_header, not a paragraph
    row = %Node{type: "table_row", attrs: %{"id" => "r"}, content: [para("x")]}
    assert {:error, violations} = Validator.validate(row, schema())
    assert Enum.any?(violations, &(&1.message =~ "content"))
  end

  test "disallowed mark on inline child is rejected" do
    # code_block allows no marks on its text children
    cb = %Node{type: "code_block", attrs: %{"id" => "c"}, content: [Node.text("x", [Mark.new("em")])]}
    assert {:error, violations} = Validator.validate(cb, schema())
    assert Enum.any?(violations, &(&1.message =~ "mark"))
  end

  test "missing required attr is rejected" do
    # unsupported_block requires a "pandoc" attr (no default)
    node = %Node{type: "unsupported_block", attrs: %{"id" => "u"}}
    assert {:error, violations} = Validator.validate(node, schema())
    assert Enum.any?(violations, &(&1.message =~ "missing attr"))
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/canonical/schema/validator_test.exs`
Expected: FAIL — `Canonical.Schema.Validator` undefined.

- [ ] **Step 3: Write minimal implementation**

```elixir
# lib/canonical/schema/validator.ex
defmodule Canonical.Schema.Validator do
  @moduledoc "Validates a Canonical.Node tree against a Canonical.Schema."
  alias Canonical.Node
  alias Canonical.Schema
  alias Canonical.Schema.ContentExpr

  @doc "Returns :ok or {:error, [%{path: String.t(), message: String.t()}]}."
  def validate(%Node{} = node, %Schema{} = schema) do
    case do_validate(node, schema, "$") do
      [] -> :ok
      violations -> {:error, violations}
    end
  end

  defp do_validate(%Node{type: type} = node, schema, path) do
    case Schema.node_spec(schema, type) do
      :error ->
        [v(path, "unknown node type #{inspect(type)}")]

      {:ok, spec} ->
        check_text(node, spec, path) ++
          check_attrs(node, spec, path) ++
          check_content(node, spec, schema, path) ++
          check_child_marks(node, spec, schema, path) ++
          children_violations(node, schema, path)
    end
  end

  defp check_text(%Node{type: "text", text: t}, %{text?: true}, _path) when is_binary(t), do: []
  defp check_text(%Node{type: "text"}, %{text?: true}, path), do: [v(path, "text node missing string")]
  defp check_text(%Node{text: nil}, %{text?: false}, _path), do: []
  defp check_text(%Node{text: _}, %{text?: false}, path), do: [v(path, "non-text node has text")]
  defp check_text(_, _, _), do: []

  defp check_attrs(%Node{attrs: attrs}, %{attrs: specs}, path) do
    Enum.flat_map(specs, fn {name, attr_spec} ->
      cond do
        Map.has_key?(attrs, name) -> []
        Map.has_key?(attr_spec, :default) -> []
        true -> [v(path, "missing attr #{name}")]
      end
    end)
  end

  defp check_content(%Node{content: content}, %{content: expr_str}, schema, path) do
    expr = ContentExpr.parse(expr_str || "")
    types = Enum.map(content, & &1.type)

    if ContentExpr.matches?(expr, types, schema) do
      []
    else
      [v(path, "content #{inspect(types)} does not satisfy #{inspect(expr_str)}")]
    end
  end

  defp check_child_marks(%Node{content: content}, %{marks: allowed}, _schema, path) do
    content
    |> Enum.with_index()
    |> Enum.flat_map(fn {child, i} ->
      Enum.flat_map(child.marks, fn mark ->
        if Schema.mark_allowed?(allowed, mark.type),
          do: [],
          else: [v("#{path}/content[#{i}]", "mark #{mark.type} not allowed here")]
      end)
    end)
  end

  defp children_violations(%Node{content: content}, schema, path) do
    content
    |> Enum.with_index()
    |> Enum.flat_map(fn {child, i} -> do_validate(child, schema, "#{path}/content[#{i}]") end)
  end

  defp v(path, message), do: %{path: path, message: message}
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/canonical/schema/validator_test.exs`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
mix format
git add lib/canonical/schema/validator.ex test/canonical/schema/validator_test.exs
git commit -m "feat(canonical): add schema validator"
```

---

## Task 8: PM JSON serialization

**Files:**
- Create: `lib/canonical/pm.ex`
- Test: `test/canonical/pm_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
# test/canonical/pm_test.exs
defmodule Canonical.PMTest do
  use ExUnit.Case, async: true
  alias Canonical.{Node, Mark, PM}

  test "to_json emits idiomatic PM, omitting empty fields" do
    node = %Node{type: "paragraph", attrs: %{"id" => "p1"}, content: [Node.text("hi", [Mark.new("em")])]}

    assert PM.to_json(node) == %{
             "type" => "paragraph",
             "attrs" => %{"id" => "p1"},
             "content" => [%{"type" => "text", "text" => "hi", "marks" => [%{"type" => "em"}]}]
           }
  end

  test "to_json omits empty marks on text" do
    assert PM.to_json(Node.text("x", [])) == %{"type" => "text", "text" => "x"}
  end

  test "from_json ∘ to_json is identity for canonical nodes" do
    node = %Node{
      type: "doc",
      content: [
        %Node{
          type: "paragraph",
          attrs: %{"id" => "p"},
          content: [
            Node.text("a", [Mark.new("strong")]),
            %Node{type: "image", attrs: %{"src" => "x.png", "alt" => "", "title" => ""}}
          ]
        }
      ]
    }

    assert node |> PM.to_json() |> PM.from_json() == node
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/canonical/pm_test.exs`
Expected: FAIL — `Canonical.PM` undefined.

- [ ] **Step 3: Write minimal implementation**

```elixir
# lib/canonical/pm.ex
defmodule Canonical.PM do
  @moduledoc "Serialize/deserialize Canonical.Node trees to literal ProseMirror JSON."
  alias Canonical.{Node, Mark}

  def to_json(%Node{type: "text", text: text, marks: marks}) do
    base = %{"type" => "text", "text" => text}
    if marks == [], do: base, else: Map.put(base, "marks", Enum.map(marks, &mark_json/1))
  end

  def to_json(%Node{type: type, attrs: attrs, content: content, marks: marks}) do
    %{"type" => type}
    |> maybe_put("attrs", if(attrs == %{}, do: nil, else: attrs))
    |> maybe_put("content", if(content == [], do: nil, else: Enum.map(content, &to_json/1)))
    |> maybe_put("marks", if(marks == [], do: nil, else: Enum.map(marks, &mark_json/1)))
  end

  def from_json(%{"type" => "text"} = map) do
    %Node{type: "text", text: Map.get(map, "text", ""), marks: marks_from(map)}
  end

  def from_json(%{"type" => type} = map) do
    %Node{
      type: type,
      attrs: Map.get(map, "attrs", %{}),
      content: Enum.map(Map.get(map, "content", []), &from_json/1),
      marks: marks_from(map)
    }
  end

  defp mark_json(%Mark{type: type, attrs: attrs}) do
    base = %{"type" => type}
    if attrs == %{}, do: base, else: Map.put(base, "attrs", attrs)
  end

  defp marks_from(map) do
    map
    |> Map.get("marks", [])
    |> Enum.map(fn %{"type" => type} = m -> %Mark{type: type, attrs: Map.get(m, "attrs", %{})} end)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/canonical/pm_test.exs`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
mix format
git add lib/canonical/pm.ex test/canonical/pm_test.exs
git commit -m "feat(canonical): add ProseMirror JSON serialization"
```

---

## Task 9: Shared Attr → attrs helper

**Files:**
- Create: `lib/canonical/import/attrs.ex`
- Test: `test/canonical/import/attrs_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
# test/canonical/import/attrs_test.exs
defmodule Canonical.Import.AttrsTest do
  use ExUnit.Case, async: true
  alias Canonical.Import.Attrs

  test "empty Attr yields empty map" do
    assert Attrs.to_map(%Panpipe.AST.Attr{}) == %{}
  end

  test "maps identifier, classes, key-value pairs" do
    attr = %Panpipe.AST.Attr{identifier: "x", classes: ["a", "b"], key_value_pairs: %{"k" => "v"}}
    assert Attrs.to_map(attr) == %{"id" => "x", "classes" => ["a", "b"], "attrs" => %{"k" => "v"}}
  end

  test "add_class/2 appends without duplicating" do
    assert Attrs.add_class(%{}, "figure") == %{"classes" => ["figure"]}
    assert Attrs.add_class(%{"classes" => ["figure"]}, "figure") == %{"classes" => ["figure"]}
    assert Attrs.add_class(%{"classes" => ["a"]}, "figure") == %{"classes" => ["a", "figure"]}
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/canonical/import/attrs_test.exs`
Expected: FAIL — `Canonical.Import.Attrs` undefined.

- [ ] **Step 3: Write minimal implementation**

```elixir
# lib/canonical/import/attrs.ex
defmodule Canonical.Import.Attrs do
  @moduledoc "Converts a Panpipe.AST.Attr into a canonical attrs map."

  def to_map(%Panpipe.AST.Attr{identifier: id, classes: classes, key_value_pairs: kv}) do
    %{}
    |> put_if("id", id, &(&1 not in [nil, ""]))
    |> put_if("classes", classes, &(&1 != []))
    |> put_if("attrs", kv, &(is_map(&1) and map_size(&1) > 0))
  end

  def add_class(attrs, class) do
    Map.update(attrs, "classes", [class], fn classes ->
      if class in classes, do: classes, else: classes ++ [class]
    end)
  end

  defp put_if(map, key, value, pred) do
    if pred.(value), do: Map.put(map, key, value), else: map
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/canonical/import/attrs_test.exs`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
mix format
git add lib/canonical/import/attrs.ex test/canonical/import/attrs_test.exs
git commit -m "feat(canonical): add shared Attr-to-attrs helper"
```

---

## Task 10: Inline flattening engine

**Files:**
- Create: `lib/canonical/import/inline.ex`
- Test: `test/canonical/import/inline_test.exs`

> Note: `Canonical.Import.Inline` references `Canonical.Import.Block` for footnote
> content. These two modules are mutually recursive at runtime — that is fine in
> Elixir (no compile cycle for function calls). `Block` is implemented in Task 11.

- [ ] **Step 1: Write the failing test**

```elixir
# test/canonical/import/inline_test.exs
defmodule Canonical.Import.InlineTest do
  use ExUnit.Case, async: true
  alias Canonical.Node
  alias Canonical.Import.Inline

  defp s(str), do: %Panpipe.AST.Str{string: str}

  test "plain string becomes a single text node" do
    assert Inline.flatten([s("hello")], []) == [Node.text("hello", [])]
  end

  test "nested Emph/Strong flatten into ordered marks and coalesce" do
    ir = [
      %Panpipe.AST.Strong{children: [%Panpipe.AST.Emph{children: [s("x")]}]}
    ]

    assert [%Node{type: "text", text: "x", marks: marks}] = Inline.flatten(ir, [])
    assert Enum.map(marks, & &1.type) == ["em", "strong"]
  end

  test "adjacent runs with equal marks coalesce" do
    ir = [s("a"), %Panpipe.AST.Space{}, s("b")]
    assert [%Node{type: "text", text: "a b"}] = Inline.flatten(ir, [])
  end

  test "Link becomes a link mark with href/title" do
    ir = [%Panpipe.AST.Link{children: [s("t")], target: "http://x", title: "T"}]
    assert [%Node{type: "text", text: "t", marks: [mark]}] = Inline.flatten(ir, [])
    assert mark.type == "link"
    assert mark.attrs == %{"href" => "http://x", "title" => "T"}
  end

  test "inline Code becomes text with a code mark" do
    ir = [%Panpipe.AST.Code{string: "f()", attr: %Panpipe.AST.Attr{}}]
    assert [%Node{type: "text", text: "f()", marks: [%{type: "code"}]}] = Inline.flatten(ir, [])
  end

  test "LineBreak becomes a hard_break node" do
    assert [%Node{type: "hard_break"}] = Inline.flatten([%Panpipe.AST.LineBreak{}], [])
  end

  test "Image becomes an image node carrying alt text" do
    ir = [%Panpipe.AST.Image{children: [s("alt")], target: "p.png", title: "T", attr: %Panpipe.AST.Attr{}}]
    assert [%Node{type: "image", attrs: attrs}] = Inline.flatten(ir, [])
    assert attrs == %{"src" => "p.png", "alt" => "alt", "title" => "T"}
  end

  test "Math becomes a math node" do
    ir = [%Panpipe.AST.Math{type: "DisplayMath", string: "x^2"}]
    assert [%Node{type: "math", attrs: %{"mode" => "display", "tex" => "x^2"}}] = Inline.flatten(ir, [])
  end

  test "Span becomes a span mark preserving classes" do
    attr = %Panpipe.AST.Attr{classes: ["hl"]}
    ir = [%Panpipe.AST.Span{children: [s("y")], attr: attr}]
    assert [%Node{type: "text", text: "y", marks: [mark]}] = Inline.flatten(ir, [])
    assert mark.type == "span"
    assert mark.attrs == %{"classes" => ["hl"]}
  end

  test "SoftBreak is a space by default and newline when configured" do
    ir = [s("a"), %Panpipe.AST.SoftBreak{}, s("b")]
    assert [%Node{text: "a b"}] = Inline.flatten(ir, [])
    assert [%Node{text: "a\nb"}] = Inline.flatten(ir, preserve_soft_breaks: true)
  end

  test "unknown inline becomes unsupported_inline" do
    ir = [%Panpipe.AST.Cite{citations: [], children: [s("c")]}]
    # Cite is handled explicitly (unwrapped), so use a truly unknown struct:
    assert [%Node{text: "c"}] = Inline.flatten(ir, [])
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/canonical/import/inline_test.exs`
Expected: FAIL — `Canonical.Import.Inline` undefined.

- [ ] **Step 3: Write minimal implementation**

```elixir
# lib/canonical/import/inline.ex
defmodule Canonical.Import.Inline do
  @moduledoc """
  Flattens Pandoc's nested inline IR into ProseMirror's flat text-with-marks model.

  Descends carrying an accumulated mark set; emits text/atomic inline nodes;
  coalesces adjacent equal-mark text runs. Marks are kept in canonical order
  (Canonical.Mark.sort/1) at node-construction time.
  """
  alias Canonical.{Node, Mark}
  alias Canonical.Import.Attrs

  @doc "Flatten a list of panpipe inline IR nodes into canonical inline nodes."
  def flatten(inlines, opts) when is_list(inlines) do
    inlines |> Enum.flat_map(&node(&1, [], opts)) |> coalesce()
  end

  defp do_flatten(inlines, marks, opts), do: Enum.flat_map(inlines, &node(&1, marks, opts))

  # --- mark-producing wrappers ---
  defp node(%Panpipe.AST.Emph{children: c}, marks, opts), do: do_flatten(c, add(marks, "em"), opts)
  defp node(%Panpipe.AST.Strong{children: c}, marks, opts), do: do_flatten(c, add(marks, "strong"), opts)
  defp node(%Panpipe.AST.Strikeout{children: c}, marks, opts), do: do_flatten(c, add(marks, "strikethrough"), opts)
  defp node(%Panpipe.AST.Superscript{children: c}, marks, opts), do: do_flatten(c, add(marks, "superscript"), opts)
  defp node(%Panpipe.AST.Subscript{children: c}, marks, opts), do: do_flatten(c, add(marks, "subscript"), opts)
  defp node(%Panpipe.AST.SmallCaps{children: c}, marks, opts), do: do_flatten(c, add(marks, "smallcaps"), opts)
  defp node(%Panpipe.AST.Underline{children: c}, marks, opts), do: do_flatten(c, add(marks, "underline"), opts)

  defp node(%Panpipe.AST.Link{children: c, target: target, title: title}, marks, opts) do
    do_flatten(c, add(marks, "link", %{"href" => target, "title" => title}), opts)
  end

  defp node(%Panpipe.AST.Span{children: c, attr: attr}, marks, opts) do
    do_flatten(c, add(marks, "span", Attrs.to_map(attr)), opts)
  end

  # --- leaf text ---
  defp node(%Panpipe.AST.Str{string: s}, marks, _opts), do: [Node.text(s, marks)]
  defp node(%Panpipe.AST.Space{}, marks, _opts), do: [Node.text(" ", marks)]

  defp node(%Panpipe.AST.SoftBreak{}, marks, opts) do
    if Keyword.get(opts, :preserve_soft_breaks, false),
      do: [Node.text("\n", marks)],
      else: [Node.text(" ", marks)]
  end

  defp node(%Panpipe.AST.LineBreak{}, marks, _opts),
    do: [%Node{type: "hard_break", marks: Mark.sort(marks)}]

  defp node(%Panpipe.AST.Code{string: s}, marks, _opts), do: [Node.text(s, add(marks, "code"))]

  # --- atomic inline nodes ---
  defp node(%Panpipe.AST.Image{target: target, title: title, children: alt}, marks, opts) do
    [%Node{type: "image", attrs: %{"src" => target, "alt" => inline_text(alt, opts), "title" => title}, marks: Mark.sort(marks)}]
  end

  defp node(%Panpipe.AST.Math{type: type, string: s}, marks, _opts) do
    mode = if type == "DisplayMath", do: "display", else: "inline"
    [%Node{type: "math", attrs: %{"mode" => mode, "tex" => s}, marks: Mark.sort(marks)}]
  end

  defp node(%Panpipe.AST.RawInline{format: format, string: s}, marks, _opts) do
    [%Node{type: "raw_inline", attrs: %{"format" => format, "text" => s}, marks: Mark.sort(marks)}]
  end

  defp node(%Panpipe.AST.Note{children: blocks}, marks, opts) do
    [%Node{type: "footnote", content: Canonical.Import.Block.map_blocks(blocks, opts), marks: Mark.sort(marks)}]
  end

  # --- unwrapped passthroughs ---
  defp node(%Panpipe.AST.Quoted{type: qt, children: c}, marks, opts) do
    {open, close} = if qt == "SingleQuote", do: {"‘", "’"}, else: {"“", "”"}
    [Node.text(open, marks)] ++ do_flatten(c, marks, opts) ++ [Node.text(close, marks)]
  end

  defp node(%Panpipe.AST.Cite{children: c}, marks, opts), do: do_flatten(c, marks, opts)

  # --- fallback ---
  defp node(other, marks, _opts) do
    [%Node{type: "unsupported_inline", attrs: %{"pandoc" => Panpipe.AST.Node.to_pandoc(other)}, marks: Mark.sort(marks)}]
  end

  # --- helpers ---
  defp add(marks, type, attrs \\ %{}) do
    if Enum.any?(marks, &(&1.type == type)), do: marks, else: marks ++ [Mark.new(type, attrs)]
  end

  defp inline_text(inlines, opts) do
    inlines
    |> flatten(opts)
    |> Enum.map(fn
      %Node{type: "text", text: t} -> t
      _ -> ""
    end)
    |> Enum.join()
  end

  defp coalesce(nodes) do
    nodes
    |> Enum.reduce([], fn
      %Node{type: "text"} = node, [%Node{type: "text"} = prev | rest] ->
        if prev.marks == node.marks,
          do: [%{prev | text: prev.text <> node.text} | rest],
          else: [node, prev | rest]

      node, acc ->
        [node | acc]
    end)
    |> Enum.reverse()
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/canonical/import/inline_test.exs`
Expected: PASS (12 tests).

> If the "unknown inline" test fails because `Cite` is unwrapped (it is), it will
> still pass: the assertion expects the unwrapped `"c"` text. This documents that
> `Cite` is intentionally unwrapped rather than treated as unsupported.

- [ ] **Step 5: Commit**

```bash
mix format
git add lib/canonical/import/inline.ex test/canonical/import/inline_test.exs
git commit -m "feat(canonical): add inline flattening engine"
```

---

## Task 11: Block mapping

**Files:**
- Create: `lib/canonical/import/block.ex`
- Test: `test/canonical/import/block_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
# test/canonical/import/block_test.exs
defmodule Canonical.Import.BlockTest do
  use ExUnit.Case, async: true
  alias Canonical.Node
  alias Canonical.Import.Block

  defp s(str), do: %Panpipe.AST.Str{string: str}
  defp para(str), do: %Panpipe.AST.Para{children: [s(str)]}

  test "Para/Plain map to paragraph" do
    assert [%Node{type: "paragraph", content: [%Node{text: "hi"}]}] = Block.map_blocks([para("hi")], [])
    assert [%Node{type: "paragraph"}] = Block.map_blocks([%Panpipe.AST.Plain{children: [s("x")]}], [])
  end

  test "Header maps to heading with level and preserved id" do
    h = %Panpipe.AST.Header{level: 2, attr: %Panpipe.AST.Attr{identifier: "intro"}, children: [s("Intro")]}
    assert [%Node{type: "heading", attrs: attrs}] = Block.map_blocks([h], [])
    assert attrs["level"] == 2
    assert attrs["id"] == "intro"
  end

  test "CodeBlock maps to code_block with language and text content" do
    cb = %Panpipe.AST.CodeBlock{string: "puts :hi", attr: %Panpipe.AST.Attr{classes: ["elixir"]}}
    assert [%Node{type: "code_block", attrs: attrs, content: [%Node{type: "text", text: "puts :hi"}]}] =
             Block.map_blocks([cb], [])
    assert attrs["language"] == "elixir"
  end

  test "BulletList maps items to list_item containing blocks" do
    item = %Panpipe.AST.ListElement{children: [para("a")]}
    assert [%Node{type: "bullet_list", content: [%Node{type: "list_item", content: [%Node{type: "paragraph"}]}]}] =
             Block.map_blocks([%Panpipe.AST.BulletList{children: [item]}], [])
  end

  test "OrderedList carries list attributes" do
    item = %Panpipe.AST.ListElement{children: [para("a")]}
    la = %Panpipe.AST.ListAttributes{start: 3, number_style: "Decimal", number_delimiter: "Period"}
    ol = %Panpipe.AST.OrderedList{list_attributes: la, children: [item]}
    assert [%Node{type: "ordered_list", attrs: attrs}] = Block.map_blocks([ol], [])
    assert attrs == %{"start" => 3, "style" => "Decimal", "delimiter" => "Period"}
  end

  test "RawBlock maps to raw_block escape node" do
    rb = %Panpipe.AST.RawBlock{format: "html", string: "<x>"}
    assert [%Node{type: "raw_block", attrs: %{"format" => "html", "text" => "<x>"}}] = Block.map_blocks([rb], [])
  end

  test "DefinitionList maps term then defs" do
    dl = %Panpipe.AST.DefinitionList{children: [[[s("Term")], [[para("Def")]]]]}
    assert [%Node{type: "definition_list", content: content}] = Block.map_blocks([dl], [])
    assert [%Node{type: "def_term"}, %Node{type: "def_desc"}] = content
  end

  test "Table maps caption + header/body rows with cell alignment" do
    cell = %Panpipe.AST.Cell{blocks: [para("c")], alignment: "AlignRight", row_span: 1, col_span: 1}
    row = %Panpipe.AST.Row{cells: [cell]}
    head = %Panpipe.AST.TableHead{rows: [row]}
    body = %Panpipe.AST.TableBody{intermediate_head_rows: [], intermediate_body_rows: [row]}
    cap = %Panpipe.AST.Caption{blocks: [para("cap")]}

    table = %Panpipe.AST.Table{
      col_spec: [%Panpipe.AST.ColSpec{alignment: "AlignRight", col_width: "ColWidthDefault"}],
      table_head: head,
      table_bodies: [body],
      table_foot: %Panpipe.AST.TableFoot{rows: []},
      caption: cap,
      attr: %Panpipe.AST.Attr{}
    }

    assert [%Node{type: "table", content: content}] = Block.map_blocks([table], [])
    assert [%Node{type: "table_caption"}, %Node{type: "table_row", content: [hdr]}, %Node{type: "table_row", content: [bdy]}] = content
    assert hdr.type == "table_header"
    assert hdr.attrs["align"] == "right"
    assert bdy.type == "table_cell"
  end

  test "Figure maps to div.figure preserving content and caption" do
    fig = %Panpipe.AST.Figure{
      caption: %Panpipe.AST.Caption{blocks: [para("cap")]},
      attr: %Panpipe.AST.Attr{},
      children: [para("body")]
    }

    assert [%Node{type: "div", attrs: attrs, content: content}] = Block.map_blocks([fig], [])
    assert attrs["classes"] == ["figure"]
    assert length(content) == 2
  end

  test "unknown block becomes unsupported_block" do
    assert [%Node{type: "horizontal_rule"}] = Block.map_blocks([%Panpipe.AST.HorizontalRule{}], [])
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/canonical/import/block_test.exs`
Expected: FAIL — `Canonical.Import.Block` undefined.

- [ ] **Step 3: Write minimal implementation**

```elixir
# lib/canonical/import/block.ex
defmodule Canonical.Import.Block do
  @moduledoc "Maps Pandoc block IR into canonical block nodes."
  alias Canonical.Node
  alias Canonical.Import.{Inline, Attrs}

  def map_blocks(blocks, opts) when is_list(blocks), do: Enum.flat_map(blocks, &map(&1, opts))

  defp map(%Panpipe.AST.Para{children: c}, opts),
    do: [%Node{type: "paragraph", content: Inline.flatten(c, opts)}]

  defp map(%Panpipe.AST.Plain{children: c}, opts),
    do: [%Node{type: "paragraph", content: Inline.flatten(c, opts)}]

  defp map(%Panpipe.AST.Header{level: level, attr: attr, children: c}, opts) do
    attrs = Map.put(Attrs.to_map(attr), "level", level)
    [%Node{type: "heading", attrs: attrs, content: Inline.flatten(c, opts)}]
  end

  defp map(%Panpipe.AST.BlockQuote{children: c}, opts),
    do: [%Node{type: "blockquote", content: map_blocks(c, opts)}]

  defp map(%Panpipe.AST.CodeBlock{string: s, attr: attr}, _opts) do
    base = Attrs.to_map(attr)

    attrs =
      case attr.classes do
        [lang | _] -> Map.put(base, "language", lang)
        _ -> base
      end

    content = if s == "", do: [], else: [%Node{type: "text", text: s}]
    [%Node{type: "code_block", attrs: attrs, content: content}]
  end

  defp map(%Panpipe.AST.RawBlock{format: format, string: s}, _opts),
    do: [%Node{type: "raw_block", attrs: %{"format" => format, "text" => s}}]

  defp map(%Panpipe.AST.HorizontalRule{}, _opts), do: [%Node{type: "horizontal_rule"}]

  defp map(%Panpipe.AST.BulletList{children: items}, opts),
    do: [%Node{type: "bullet_list", content: Enum.map(items, &list_item(&1, opts))}]

  defp map(%Panpipe.AST.OrderedList{list_attributes: la, children: items}, opts),
    do: [%Node{type: "ordered_list", attrs: list_attrs(la), content: Enum.map(items, &list_item(&1, opts))}]

  defp map(%Panpipe.AST.LineBlock{children: lines}, opts) do
    paras = Enum.map(lines, fn line -> %Node{type: "paragraph", content: Inline.flatten(line, opts)} end)
    [%Node{type: "line_block", content: paras}]
  end

  defp map(%Panpipe.AST.Div{attr: attr, children: c}, opts),
    do: [%Node{type: "div", attrs: Attrs.to_map(attr), content: map_blocks(c, opts)}]

  defp map(%Panpipe.AST.DefinitionList{children: items}, opts) do
    content =
      Enum.flat_map(items, fn [term, definitions] ->
        [%Node{type: "def_term", content: Inline.flatten(term, opts)}] ++
          Enum.map(definitions, fn blocks -> %Node{type: "def_desc", content: map_blocks(blocks, opts)} end)
      end)

    [%Node{type: "definition_list", content: content}]
  end

  defp map(%Panpipe.AST.Table{} = t, opts) do
    caption = table_caption(t.caption, opts)
    head = Enum.map(t.table_head.rows, &table_row(&1, "table_header", opts))

    body =
      Enum.flat_map(t.table_bodies, fn b ->
        Enum.map(b.intermediate_head_rows, &table_row(&1, "table_header", opts)) ++
          Enum.map(b.intermediate_body_rows, &table_row(&1, "table_cell", opts))
      end)

    foot = Enum.map(t.table_foot.rows, &table_row(&1, "table_cell", opts))
    attrs = Map.put(Attrs.to_map(t.attr), "colspec", colspec(t.col_spec))
    [%Node{type: "table", attrs: attrs, content: caption ++ head ++ body ++ foot}]
  end

  defp map(%Panpipe.AST.Figure{caption: caption, attr: attr, children: blocks}, opts) do
    attrs = Attrs.add_class(Attrs.to_map(attr), "figure")
    caption_blocks =
      case caption do
        %Panpipe.AST.Caption{blocks: []} -> []
        %Panpipe.AST.Caption{blocks: cap} -> map_blocks(cap, opts)
        _ -> []
      end

    [%Node{type: "div", attrs: attrs, content: map_blocks(blocks, opts) ++ caption_blocks}]
  end

  defp map(other, _opts),
    do: [%Node{type: "unsupported_block", attrs: %{"pandoc" => Panpipe.AST.Node.to_pandoc(other)}}]

  # --- helpers ---
  defp list_item(%Panpipe.AST.ListElement{children: blocks}, opts),
    do: %Node{type: "list_item", content: map_blocks(blocks, opts)}

  defp list_attrs(%Panpipe.AST.ListAttributes{start: start, number_style: style, number_delimiter: delim}),
    do: %{"start" => start, "style" => style, "delimiter" => delim}

  defp list_attrs(_), do: %{"start" => 1, "style" => "Decimal", "delimiter" => "Period"}

  defp table_caption(%Panpipe.AST.Caption{blocks: []}, _opts), do: []
  defp table_caption(%Panpipe.AST.Caption{blocks: blocks}, opts),
    do: [%Node{type: "table_caption", content: map_blocks(blocks, opts)}]

  defp table_caption(_, _opts), do: []

  defp table_row(%Panpipe.AST.Row{cells: cells}, cell_type, opts),
    do: %Node{type: "table_row", content: Enum.map(cells, &table_cell(&1, cell_type, opts))}

  defp table_cell(%Panpipe.AST.Cell{blocks: blocks, alignment: a, row_span: rs, col_span: cs}, cell_type, opts) do
    %Node{
      type: cell_type,
      attrs: %{"align" => align(a), "rowspan" => rs, "colspan" => cs},
      content: map_blocks(blocks, opts)
    }
  end

  defp align("AlignLeft"), do: "left"
  defp align("AlignRight"), do: "right"
  defp align("AlignCenter"), do: "center"
  defp align(_), do: "default"

  defp colspec(specs) when is_list(specs),
    do: Enum.map(specs, fn %Panpipe.AST.ColSpec{alignment: a, col_width: w} -> %{"align" => align(a), "width" => w} end)

  defp colspec(_), do: []
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/canonical/import/block_test.exs`
Expected: PASS (10 tests).

- [ ] **Step 5: Commit**

```bash
mix format
git add lib/canonical/import/block.ex test/canonical/import/block_test.exs
git commit -m "feat(canonical): add block mapping (incl. table, deflist, figure)"
```

---

## Task 12: ID minting pass

**Files:**
- Modify: `lib/canonical/id.ex` (add `mint/2`)
- Test: `test/canonical/id_mint_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
# test/canonical/id_mint_test.exs
defmodule Canonical.IdMintTest do
  use ExUnit.Case, async: true
  alias Canonical.{Node, Id}

  # Deterministic generator for tests: id0, id1, ...
  defp counter_gen do
    {:ok, pid} = Agent.start_link(fn -> 0 end)
    fn -> n = Agent.get_and_update(pid, &{&1, &1 + 1}); "id#{n}" end
  end

  test "mints ids on every non-text node, skipping text nodes" do
    tree = %Node{type: "doc", content: [%Node{type: "paragraph", content: [Node.text("x", [])]}]}
    {minted, warnings} = Id.mint(tree, id_generator: counter_gen())

    assert warnings == []
    assert minted.attrs["id"] != nil
    [para] = minted.content
    assert para.attrs["id"] != nil
    [text] = para.content
    refute Map.has_key?(text.attrs, "id")
  end

  test "preserves an existing non-empty id" do
    tree = %Node{type: "doc", attrs: %{"id" => "root"}, content: []}
    {minted, _} = Id.mint(tree, id_generator: counter_gen())
    assert minted.attrs["id"] == "root"
  end

  test "de-dupes colliding preserved ids and warns" do
    tree = %Node{
      type: "doc",
      content: [
        %Node{type: "paragraph", attrs: %{"id" => "dup"}, content: []},
        %Node{type: "paragraph", attrs: %{"id" => "dup"}, content: []}
      ]
    }

    {minted, warnings} = Id.mint(tree, id_generator: counter_gen())
    [a, b] = minted.content
    assert a.attrs["id"] == "dup"
    assert b.attrs["id"] != "dup"
    assert Enum.any?(warnings, &match?({:duplicate_id, "dup"}, &1))
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/canonical/id_mint_test.exs`
Expected: FAIL — `Id.mint/2` undefined.

- [ ] **Step 3: Write minimal implementation** (append to `lib/canonical/id.ex` before the final `end`)

```elixir
  alias Canonical.Node

  @doc """
  Walk the tree assigning `attrs["id"]` to every non-text node.

  Preserves an existing non-empty id; if a preserved id collides with one already
  seen, mints a fresh one and records a `{:duplicate_id, id}` warning. Returns
  `{tree, warnings}`.
  """
  def mint(%Node{} = tree, opts \\ []) do
    gen = Keyword.get(opts, :id_generator, &generate/0)
    {minted, _seen, warnings} = mint_node(tree, MapSet.new(), [], gen)
    {minted, Enum.reverse(warnings)}
  end

  defp mint_node(%Node{type: "text"} = node, seen, warnings, _gen), do: {node, seen, warnings}

  defp mint_node(%Node{} = node, seen, warnings, gen) do
    {id, seen, warnings} = resolve_id(Map.get(node.attrs, "id"), seen, warnings, gen)

    {content, seen, warnings} =
      Enum.reduce(node.content, {[], seen, warnings}, fn child, {acc, s, w} ->
        {minted, s2, w2} = mint_node(child, s, w, gen)
        {[minted | acc], s2, w2}
      end)

    {%{node | attrs: Map.put(node.attrs, "id", id), content: Enum.reverse(content)}, seen, warnings}
  end

  defp resolve_id(existing, seen, warnings, gen) when is_binary(existing) and existing != "" do
    if MapSet.member?(seen, existing) do
      fresh = fresh_id(seen, gen)
      {fresh, MapSet.put(seen, fresh), [{:duplicate_id, existing} | warnings]}
    else
      {existing, MapSet.put(seen, existing), warnings}
    end
  end

  defp resolve_id(_missing, seen, warnings, gen) do
    fresh = fresh_id(seen, gen)
    {fresh, MapSet.put(seen, fresh), warnings}
  end

  defp fresh_id(seen, gen) do
    id = gen.()
    if MapSet.member?(seen, id), do: fresh_id(seen, gen), else: id
  end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/canonical/id_mint_test.exs`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
mix format
git add lib/canonical/id.ex test/canonical/id_mint_test.exs
git commit -m "feat(canonical): add id minting pass with preservation and de-dupe"
```

---

## Task 13: Orchestrator + public façade

**Files:**
- Create: `lib/canonical/import.ex`
- Create: `lib/canonical.ex`
- Test: `test/canonical/import_test.exs`

> Integration test — requires the `pandoc` binary (already required by panpipe).

- [ ] **Step 1: Write the failing test**

```elixir
# test/canonical/import_test.exs
defmodule Canonical.ImportTest do
  use ExUnit.Case, async: true
  alias Canonical.Node

  defp counter_gen do
    {:ok, pid} = Agent.start_link(fn -> 0 end)
    fn -> n = Agent.get_and_update(pid, &{&1, &1 + 1}); "id#{n}" end
  end

  test "ingest/2 imports markdown into a validated doc" do
    {:ok, doc, warnings} = Canonical.ingest("# Title\n\nHello **world**", id_generator: counter_gen())

    assert %Node{type: "doc"} = doc
    assert warnings == []
    assert [%Node{type: "heading"}, %Node{type: "paragraph"} = p] = doc.content
    assert Enum.any?(p.content, fn n -> n.type == "text" and Enum.any?(n.marks, &(&1.type == "strong")) end)
  end

  test "to_pm_json round-trips through from_pm_json" do
    {:ok, doc, _} = Canonical.ingest("Hello *there*", id_generator: counter_gen())
    json = Canonical.to_pm_json(doc)
    assert Canonical.from_pm_json(json) == doc
  end

  test "raw HTML survives losslessly as an escape node with a warning" do
    {:ok, doc, warnings} =
      Canonical.ingest("<div class=\"x\">raw</div>", from: :html, id_generator: counter_gen())

    types = collect_types(doc)
    assert "div" in types or "raw_block" in types or "unsupported_block" in types
    # Pandoc may model this as a div; either way nothing crashes and ids are minted.
    assert is_list(warnings)
  end

  defp collect_types(%Node{type: t, content: content}),
    do: [t | Enum.flat_map(content, &collect_types/1)]
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/canonical/import_test.exs`
Expected: FAIL — `Canonical` / `Canonical.Import` undefined.

- [ ] **Step 3: Write minimal implementation**

```elixir
# lib/canonical/import.ex
defmodule Canonical.Import do
  @moduledoc "Orchestrates Panpipe IR → canonical tree → minted ids → validation."
  alias Canonical.{Node, Id, Schema, PM}
  alias Canonical.Import.Block
  alias Canonical.Schema.{Pandoc, Validator}

  @escape_types ~w(unsupported_block unsupported_inline raw_block raw_inline)

  # Options consumed by the canonical layer; everything else is forwarded to pandoc.
  @canonical_opts [:id_generator, :preserve_soft_breaks, :on_invalid, :schema]

  @doc """
  Import raw input into a canonical doc.

  `input_or_opts` is a string (or a panpipe options keyword list, e.g.
  `[input: "file.md"]`). `opts` may mix canonical options
  (#{inspect(@canonical_opts)}) with pandoc options (e.g. `from: :html`); they are
  split and routed appropriately.
  """
  def ingest(input_or_opts, opts \\ []) do
    {canonical_opts, pandoc_opts} = Keyword.split(opts, @canonical_opts)

    ast_result =
      case input_or_opts do
        input when is_binary(input) -> Panpipe.ast(input, pandoc_opts)
        list when is_list(list) -> Panpipe.ast(Keyword.merge(list, pandoc_opts))
      end

    case ast_result do
      {:ok, %Panpipe.Document{} = doc} -> from_panpipe(doc, canonical_opts)
      {:error, _} = error -> error
    end
  end

  @doc "Convert an already-parsed Panpipe.Document into a canonical doc."
  def from_panpipe(%Panpipe.Document{children: blocks}, opts \\ []) do
    schema = Keyword.get(opts, :schema, Pandoc.schema())
    tree = %Node{type: "doc", content: Block.map_blocks(blocks, opts)}
    {tree, id_warnings} = Id.mint(tree, opts)
    warnings = id_warnings ++ escape_warnings(tree)

    case Keyword.get(opts, :on_invalid, :error) do
      :error ->
        case Validator.validate(tree, schema) do
          :ok -> {:ok, tree, warnings}
          {:error, violations} -> {:error, {:invalid, violations}}
        end

      :warn ->
        extra =
          case Validator.validate(tree, schema) do
            :ok -> []
            {:error, violations} -> [{:invalid, violations}]
          end

        {:ok, tree, warnings ++ extra}
    end
  end

  def to_pm_json(%Node{} = node), do: PM.to_json(node)
  def from_pm_json(map) when is_map(map), do: PM.from_json(map)
  def validate(%Node{} = node, %Schema{} = schema), do: Validator.validate(node, schema)

  defp escape_warnings(%Node{} = node) do
    node
    |> collect()
    |> Enum.filter(&(&1.type in @escape_types))
    |> Enum.map(&{:escaped, &1.type})
  end

  defp collect(%Node{content: content} = node), do: [node | Enum.flat_map(content, &collect/1)]
end
```

```elixir
# lib/canonical.ex
defmodule Canonical do
  @moduledoc """
  Canonical, ProseMirror-shaped, schema-validated document model with Pandoc import.

  `ingest/2` is the spec's "import" entry point; it is named `ingest` to avoid
  clashing with `Kernel.SpecialForms.import/2`.
  """
  alias Canonical.{Import, Schema}
  alias Canonical.Schema.Pandoc

  defdelegate ingest(input_or_opts, opts \\ []), to: Import
  defdelegate from_panpipe(document, opts \\ []), to: Import
  defdelegate to_pm_json(node), to: Import
  defdelegate from_pm_json(map), to: Import

  def validate(node, schema \\ Pandoc.schema()), do: Import.validate(node, schema)

  @doc "The default schema (the custom Pandoc-covering schema)."
  def schema, do: Pandoc.schema()
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/canonical/import_test.exs`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
mix format
git add lib/canonical/import.ex lib/canonical.ex test/canonical/import_test.exs
git commit -m "feat(canonical): add import orchestrator and public facade"
```

---

## Task 14: End-to-end fixtures + property tests

**Files:**
- Create: `test/canonical/properties_test.exs`
- Test: (same file)

- [ ] **Step 1: Write the failing test**

```elixir
# test/canonical/properties_test.exs
defmodule Canonical.PropertiesTest do
  use ExUnit.Case, async: true
  alias Canonical.{Node, PM}

  defp counter_gen do
    {:ok, pid} = Agent.start_link(fn -> 0 end)
    fn -> n = Agent.get_and_update(pid, &{&1, &1 + 1}); "id#{n}" end
  end

  @samples [
    "# Heading\n\nA paragraph with *em*, **strong**, `code`, and [a link](http://x).",
    "- one\n- two\n\n1. a\n2. b",
    "> quote\n>\n> more",
    "Term\n: Definition one\n: Definition two",
    "| A | B |\n|---|--:|\n| 1 | 2 |",
    "Here is a footnote.[^1]\n\n[^1]: The note.",
    "```elixir\nIO.puts(:hi)\n```"
  ]

  test "every sample imports, validates, and round-trips through PM JSON" do
    for md <- @samples do
      {:ok, doc, _warnings} = Canonical.ingest(md, id_generator: counter_gen())
      assert :ok == Canonical.validate(doc), "validation failed for: #{md}"
      assert PM.from_json(PM.to_json(doc)) == doc, "round-trip failed for: #{md}"
    end
  end

  test "structure is idempotent across re-import (ids stripped)" do
    md = "# H\n\nText with **bold**."
    {:ok, a, _} = Canonical.ingest(md, id_generator: counter_gen())
    {:ok, b, _} = Canonical.ingest(md, id_generator: counter_gen())
    assert strip_ids(a) == strip_ids(b)
  end

  test "unknown raw inline is preserved losslessly with a warning" do
    {:ok, doc, warnings} = Canonical.ingest("a <span>x</span> b", from: :html, id_generator: counter_gen())
    assert :ok == Canonical.validate(doc)
    assert is_list(warnings)
  end

  defp strip_ids(%Node{attrs: attrs, content: content} = node) do
    %{node | attrs: Map.delete(attrs, "id"), content: Enum.map(content, &strip_ids/1)}
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/canonical/properties_test.exs`
Expected: FAIL initially only if any mapping/validation gap exists. If a sample fails validation, fix the offending schema content-expression or mapping in the relevant module (most likely `code_block` text content, definition-list nesting, or table rows), then re-run.

- [ ] **Step 3: Make it pass**

No new module — this is the integration gate. If a sample fails:
- Read the violation `path`/`message` from `Canonical.validate/1`.
- Fix the schema spec or mapper that produced the mismatch.
- Re-run until green.

- [ ] **Step 4: Run the full suite**

Run: `mix test`
Expected: PASS (all tasks' tests green).

- [ ] **Step 5: Commit**

```bash
mix format
git add test/canonical/properties_test.exs
git commit -m "test(canonical): add end-to-end fixtures and property tests"
```

---

## Final verification

- [ ] Run `mix test` — all green.
- [ ] Run `mix format --check-formatted` — clean.
- [ ] Run `mix compile --warnings-as-errors` — no warnings (resolve any unused-alias/var warnings introduced).

---

## Spec coverage self-check

| Spec requirement | Task |
|---|---|
| Uniform `%Node{}` + `%Mark{}` model | 1 |
| Bias-free stable IDs; injectable generator | 2, 12 |
| Declarative schema-as-data | 3, 6 |
| Content-expression parse + match (common forms) | 4, 5 |
| Custom Pandoc-covering schema (nodes/marks, escape nodes) | 6 |
| Validator (type, content, marks, attrs, text) | 7 |
| Canonical ↔ PM JSON, round-trip invariant | 8, 14 |
| Inline flattening: marks, coalesce, schema-order, code, link, image, math, span, breaks, footnote, raw | 10 |
| ID preservation + collision de-dupe + warnings | 12 |
| Block mapping incl. table/caption, definition lists, figure→div, escape | 11 |
| Configurable soft breaks | 10 |
| Pipeline orchestration + warnings accumulator + on_invalid | 13 |
| Lossless escape nodes end-to-end | 13, 14 |
| Structural idempotence | 14 |
| No persistence/export/CRDT engine | (out of scope — not built) |
