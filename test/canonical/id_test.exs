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
