source =
  Path.expand("../../Baileys/src/WABinary/constants.ts", __DIR__)
  |> File.read!()
  |> String.split("\n")

{double, single, _section, current} =
  Enum.reduce(source, {[], [], :none, []}, fn line, {double, single, section, current} ->
    cond do
      String.starts_with?(line, "export const DOUBLE_BYTE_TOKENS") ->
        {double, single, :double, []}

      String.starts_with?(line, "export const SINGLE_BYTE_TOKENS") ->
        {double, single, :single, []}

      section == :double and line == "\t[" ->
        {double, single, :double_group, []}

      section == :double_group and line == "\t]," ->
        {double ++ [current], single, :double, []}

      section == :double_group and line == "\t]" ->
        {double ++ [current], single, :double, []}

      section == :double and line == "] as const" ->
        {double, single, :none, []}

      section == :single and line == "]" ->
        {double, single, :none, []}

      section in [:double_group, :single] ->
        case Regex.run(~r/^\s*'([^']*)',?$/, line) do
          [_, token] when section == :double_group ->
            {double, single, section, current ++ [token]}

          [_, token] ->
            {double, single ++ [token], section, current}

          nil ->
            {double, single, section, current}
        end

      true ->
        {double, single, section, current}
    end
  end)

if current != [] or length(double) != 4 or length(single) < 200 do
  raise "could not parse Baileys token dictionary"
end

contents = """
defmodule Baileys.Binary.TokenDictionary do
  @moduledoc false

  @single #{inspect(single, limit: :infinity, printable_limit: :infinity)}
  @double #{inspect(double, limit: :infinity, printable_limit: :infinity)}

  def single, do: @single
  def double, do: @double

  def token_map do
    single =
      @single
      |> Enum.with_index()
      |> Map.new(fn {token, index} -> {token, %{index: index}} end)

    @double
    |> Enum.with_index()
    |> Enum.reduce(single, fn {dictionary, dictionary_index}, tokens ->
      dictionary
      |> Enum.with_index()
      |> Enum.reduce(tokens, fn {token, index}, acc ->
        Map.put(acc, token, %{dictionary: dictionary_index, index: index})
      end)
    end)
  end
end
"""

output = Path.expand("../lib/baileys/binary/token_dictionary.ex", __DIR__)
File.mkdir_p!(Path.dirname(output))
File.write!(output, contents |> Code.format_string!() |> IO.iodata_to_binary())
