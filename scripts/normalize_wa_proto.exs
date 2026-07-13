source_path = System.fetch_env!("WA_PROTO_SOURCE")
target_path = System.fetch_env!("WA_PROTO_TARGET")

{lines, inserted} =
  source_path
  |> File.stream!([], :line)
  |> Enum.reduce({[], nil, 0}, fn line, {lines, enum, inserted} ->
    cond do
      is_nil(enum) ->
        case Regex.run(~r/^(\s*)enum\s+([A-Za-z][A-Za-z0-9_]*)\s*\{\s*$/, line) do
          [_, indentation, name] -> {[line | lines], {indentation, name}, inserted}
          nil -> {[line | lines], nil, inserted}
        end

      true ->
        case Regex.run(~r/^\s*[A-Za-z][A-Za-z0-9_]*\s*=\s*(-?\d+)\s*;/, line) do
          [_, "0"] ->
            {[line | lines], nil, inserted}

          [_, _non_zero] ->
            {indentation, name} = enum
            zero_value = "#{indentation}    #{name}_UNSPECIFIED = 0;\n"
            {[line, zero_value | lines], nil, inserted + 1}

          nil ->
            {[line | lines], enum, inserted}
        end
    end
  end)
  |> then(fn {lines, enum, inserted} ->
    if enum, do: raise("unterminated enum while normalizing WAProto.proto")
    {Enum.reverse(lines), inserted}
  end)

if inserted != 23 do
  raise "expected to normalize 23 enums, normalized #{inserted}"
end

File.write!(target_path, lines)
