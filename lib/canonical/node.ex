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
