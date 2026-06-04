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
    ir = [
      %Panpipe.AST.Image{
        children: [s("alt")],
        target: "p.png",
        title: "T",
        attr: %Panpipe.AST.Attr{}
      }
    ]

    assert [%Node{type: "image", attrs: attrs}] = Inline.flatten(ir, [])
    assert attrs == %{"src" => "p.png", "alt" => "alt", "title" => "T"}
  end

  test "Math becomes a math node" do
    ir = [%Panpipe.AST.Math{type: "DisplayMath", string: "x^2"}]

    assert [%Node{type: "math", attrs: %{"mode" => "display", "tex" => "x^2"}}] =
             Inline.flatten(ir, [])
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

  test "Cite is unwrapped to its children" do
    ir = [%Panpipe.AST.Cite{citations: [], children: [s("c")]}]
    assert [%Node{text: "c"}] = Inline.flatten(ir, [])
  end
end
