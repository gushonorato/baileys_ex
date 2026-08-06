defmodule Baileys.Signal.WhisperProtocol do
  @moduledoc false

  import Bitwise

  def encode_whisper(ephemeral_key, counter, previous_counter, ciphertext) do
    encode_bytes(1, ephemeral_key) <>
      encode_integer(2, counter) <>
      encode_integer(3, previous_counter) <>
      encode_bytes(4, ciphertext)
  end

  def encode_pre_key(message) do
    optional_integer(1, message[:pre_key_id]) <>
      encode_bytes(2, message.base_key) <>
      encode_bytes(3, message.identity_key) <>
      encode_bytes(4, message.message) <>
      encode_integer(5, message.registration_id) <>
      encode_integer(6, message.signed_pre_key_id)
  end

  def decode_whisper(binary) do
    fields = decode_fields(binary, %{})

    %{
      ephemeral_key: fields[1],
      counter: fields[2] || 0,
      previous_counter: fields[3] || 0,
      ciphertext: fields[4]
    }
  end

  def decode_pre_key(binary) do
    fields = decode_fields(binary, %{})

    %{
      pre_key_id: fields[1],
      base_key: fields[2],
      identity_key: fields[3],
      message: fields[4],
      registration_id: fields[5],
      signed_pre_key_id: fields[6]
    }
  end

  defp optional_integer(_field, nil), do: ""
  defp optional_integer(field, value), do: encode_integer(field, value)
  defp encode_integer(field, value), do: varint(field <<< 3) <> varint(value)

  defp encode_bytes(field, value),
    do: varint(field <<< 3 ||| 2) <> varint(byte_size(value)) <> value

  defp varint(value) when value < 128, do: <<value>>
  defp varint(value), do: <<1::1, value &&& 127::7>> <> varint(value >>> 7)

  defp decode_fields(<<>>, fields), do: fields

  defp decode_fields(binary, fields) do
    {tag, rest} = read_varint(binary)
    field = tag >>> 3

    case tag &&& 7 do
      0 ->
        {value, rest} = read_varint(rest)
        decode_fields(rest, Map.put(fields, field, value))

      2 ->
        {length, rest} = read_varint(rest)
        <<value::binary-size(length), rest::binary>> = rest
        decode_fields(rest, Map.put(fields, field, value))

      wire_type ->
        raise "unsupported Signal protobuf wire type #{wire_type}"
    end
  end

  defp read_varint(binary), do: read_varint(binary, 0, 0)

  defp read_varint(<<1::1, low::7, rest::binary>>, shift, result) do
    read_varint(rest, shift + 7, result ||| low <<< shift)
  end

  defp read_varint(<<0::1, low::7, rest::binary>>, shift, result) do
    {result ||| low <<< shift, rest}
  end
end
