defmodule Canonical.PMTest do
  use ExUnit.Case, async: true
  alias Canonical.{Node, Mark, PM}

  test "to_json emits idiomatic PM, omitting empty fields" do
    node = %Node{
      type: "paragraph",
      attrs: %{"id" => "p1"},
      content: [Node.text("hi", [Mark.new("em")])]
    }

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
