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
