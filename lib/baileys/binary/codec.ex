defmodule Baileys.Binary.Codec do
  @moduledoc false

  import Bitwise

  alias Baileys.Binary.{Node, TokenDictionary}
  alias Baileys.JID

  @list_empty 0
  @dictionary_0 236
  @interop_jid 245
  @fb_jid 246
  @ad_jid 247
  @list_8 248
  @list_16 249
  @jid_pair 250
  @hex_8 251
  @binary_8 252
  @binary_20 253
  @binary_32 254
  @nibble_8 255
  @packed_max 127

  @spec encode(Node.t()) :: binary()
  def encode(%Node{} = node), do: <<0, encode_node(node)::binary>>

  @spec decode(binary()) :: {:ok, Node.t()} | {:error, term()}
  def decode(<<flags, data::binary>>) do
    with {:ok, data} <- maybe_inflate(flags, data),
         {:ok, node, <<>>} <- decode_node(data) do
      {:ok, node}
    else
      {:ok, _node, _rest} -> {:error, :trailing_data}
      error -> error
    end
  rescue
    error -> {:error, error}
  end

  def decode(_data), do: {:error, :empty_binary_node}

  defp encode_node(%Node{tag: tag, attrs: attrs, content: content}) when is_binary(tag) do
    attrs = attrs |> Enum.reject(fn {_key, value} -> is_nil(value) end) |> Enum.sort()
    size = 1 + 2 * length(attrs) + if(is_nil(content), do: 0, else: 1)

    encoded_attrs =
      Enum.map(attrs, fn {key, value} ->
        [encode_string(to_string(key)), encode_string(to_string(value))]
      end)

    IO.iodata_to_binary([
      encode_list_start(size),
      encode_string(tag),
      encoded_attrs,
      encode_content(content)
    ])
  end

  defp encode_content(nil), do: []
  defp encode_content({:text, content}), do: encode_string(content)
  defp encode_content(content) when is_binary(content), do: encode_bytes(content)

  defp encode_content(content) when is_list(content) do
    [encode_list_start(length(content)), Enum.map(content, &encode_node/1)]
  end

  defp encode_string(nil), do: <<@list_empty>>
  defp encode_string(""), do: <<@binary_8, 0>>

  defp encode_string(value) do
    case Map.get(TokenDictionary.token_map(), value) do
      %{dictionary: dictionary, index: index} -> <<@dictionary_0 + dictionary, index>>
      %{index: index} -> <<index>>
      nil -> encode_unmapped_string(value)
    end
  end

  defp encode_unmapped_string(value) do
    cond do
      nibble?(value) ->
        encode_packed(value, :nibble)

      hex?(value) ->
        encode_packed(value, :hex)

      true ->
        case JID.decode(value) do
          {:ok, jid} -> encode_jid(jid)
          {:error, :invalid_jid} -> encode_bytes(value)
        end
    end
  end

  defp encode_jid(%JID{device: device} = jid) when not is_nil(device) do
    <<@ad_jid, jid.domain_type, device, encode_string(jid.user)::binary>>
  end

  defp encode_jid(%JID{} = jid) do
    user = if jid.user == "", do: <<@list_empty>>, else: encode_string(jid.user)
    <<@jid_pair, user::binary, encode_string(jid.server)::binary>>
  end

  defp encode_bytes(value) do
    length = byte_size(value)

    cond do
      length >= 1 <<< 32 -> raise ArgumentError, "binary node value is too large"
      length >= 1 <<< 20 -> <<@binary_32, length::32, value::binary>>
      length >= 256 -> <<@binary_20, length::20, value::binary>>
      true -> <<@binary_8, length, value::binary>>
    end
  end

  defp encode_list_start(0), do: <<@list_empty>>
  defp encode_list_start(size) when size < 256, do: <<@list_8, size>>
  defp encode_list_start(size), do: <<@list_16, size::16>>

  defp nibble?(value), do: byte_size(value) <= @packed_max and value =~ ~r/^[0-9.-]+$/
  defp hex?(value), do: byte_size(value) <= @packed_max and value =~ ~r/^[0-9A-F]+$/

  defp encode_packed(value, type) do
    padding? = rem(byte_size(value), 2) == 1
    bytes = if padding?, do: value <> <<0>>, else: value

    packed =
      for <<first, second <- bytes>>, into: <<>> do
        <<pack_character(first, type)::4, pack_character(second, type)::4>>
      end

    length = div(byte_size(value) + 1, 2) ||| if(padding?, do: 128, else: 0)
    tag = if type == :nibble, do: @nibble_8, else: @hex_8
    <<tag, length, packed::binary>>
  end

  defp pack_character(0, _type), do: 15
  defp pack_character(character, _type) when character in ?0..?9, do: character - ?0
  defp pack_character(?-, :nibble), do: 10
  defp pack_character(?., :nibble), do: 11
  defp pack_character(character, :hex) when character in ?A..?F, do: character - ?A + 10

  defp maybe_inflate(flags, data) when (flags &&& 2) != 0 do
    try do
      {:ok, :zlib.uncompress(data)}
    rescue
      error -> {:error, error}
    end
  end

  defp maybe_inflate(_flags, data), do: {:ok, data}

  defp decode_node(data) do
    with {:ok, list_tag, rest} <- take_byte(data),
         {:ok, list_size, rest} <- read_list_size(list_tag, rest),
         true <- list_size > 0 || {:error, :invalid_node},
         {:ok, header_tag, rest} <- take_byte(rest),
         {:ok, header, rest} <- read_string(header_tag, rest),
         true <- header != "" || {:error, :invalid_node},
         attributes_length = (list_size - 1) >>> 1,
         {:ok, attrs, rest} <- read_attrs(attributes_length, rest, %{}),
         {:ok, content, rest} <- read_content(list_size, rest) do
      {:ok, %Node{tag: header, attrs: attrs, content: content}, rest}
    end
  end

  defp read_attrs(0, rest, attrs), do: {:ok, attrs, rest}

  defp read_attrs(count, data, attrs) do
    with {:ok, key_tag, rest} <- take_byte(data),
         {:ok, key, rest} <- read_string(key_tag, rest),
         {:ok, value_tag, rest} <- take_byte(rest),
         {:ok, value, rest} <- read_string(value_tag, rest) do
      read_attrs(count - 1, rest, Map.put(attrs, key, value))
    end
  end

  defp read_content(list_size, rest) when rem(list_size, 2) == 1, do: {:ok, nil, rest}

  defp read_content(_list_size, data) do
    with {:ok, tag, rest} <- take_byte(data) do
      cond do
        tag in [@list_empty, @list_8, @list_16] -> read_list(tag, rest)
        tag == @binary_8 -> read_sized_binary(rest, 1)
        tag == @binary_20 -> read_sized_binary(rest, 3, :int20)
        tag == @binary_32 -> read_sized_binary(rest, 4)
        true -> read_string(tag, rest)
      end
    end
  end

  defp read_list(tag, data) do
    with {:ok, size, rest} <- read_list_size(tag, data) do
      read_nodes(size, rest, [])
    end
  end

  defp read_nodes(0, rest, nodes), do: {:ok, Enum.reverse(nodes), rest}

  defp read_nodes(count, data, nodes) do
    with {:ok, node, rest} <- decode_node(data) do
      read_nodes(count - 1, rest, [node | nodes])
    end
  end

  defp read_string(tag, rest) when tag > 0 and tag < 236 do
    case Enum.at(TokenDictionary.single(), tag) do
      nil -> {:error, {:invalid_single_token, tag}}
      token -> {:ok, token, rest}
    end
  end

  defp read_string(tag, data) when tag in 236..239 do
    with {:ok, index, rest} <- take_byte(data),
         dictionary when is_list(dictionary) <- Enum.at(TokenDictionary.double(), tag - 236),
         token when is_binary(token) <- Enum.at(dictionary, index) do
      {:ok, token, rest}
    else
      _invalid -> {:error, {:invalid_double_token, tag}}
    end
  end

  defp read_string(@list_empty, rest), do: {:ok, "", rest}
  defp read_string(@binary_8, data), do: read_sized_binary(data, 1)
  defp read_string(@binary_20, data), do: read_sized_binary(data, 3, :int20)
  defp read_string(@binary_32, data), do: read_sized_binary(data, 4)
  defp read_string(@jid_pair, data), do: read_jid_pair(data)
  defp read_string(@ad_jid, data), do: read_ad_jid(data)
  defp read_string(@fb_jid, data), do: read_fb_jid(data)
  defp read_string(@interop_jid, data), do: read_interop_jid(data)
  defp read_string(tag, data) when tag in [@hex_8, @nibble_8], do: read_packed(tag, data)
  defp read_string(tag, _data), do: {:error, {:invalid_string_tag, tag}}

  defp read_jid_pair(data) do
    with {:ok, user_tag, rest} <- take_byte(data),
         {:ok, user, rest} <- read_string(user_tag, rest),
         {:ok, server_tag, rest} <- take_byte(rest),
         {:ok, server, rest} <- read_string(server_tag, rest),
         true <- server != "" || {:error, :invalid_jid_pair} do
      {:ok, "#{user}@#{server}", rest}
    end
  end

  defp read_ad_jid(<<domain_type, device, rest::binary>>) do
    with {:ok, user_tag, rest} <- take_byte(rest),
         {:ok, user, rest} <- read_string(user_tag, rest) do
      server =
        %{0 => "s.whatsapp.net", 1 => "lid", 128 => "hosted", 129 => "hosted.lid"}[domain_type]

      {:ok, JID.encode(user, server || "s.whatsapp.net", device), rest}
    end
  end

  defp read_ad_jid(_data), do: {:error, :end_of_stream}

  defp read_fb_jid(data) do
    with {:ok, user_tag, rest} <- take_byte(data),
         {:ok, user, <<device::16, rest::binary>>} <- read_string(user_tag, rest),
         {:ok, server_tag, rest} <- take_byte(rest),
         {:ok, server, rest} <- read_string(server_tag, rest) do
      {:ok, "#{user}:#{device}@#{server}", rest}
    else
      _invalid -> {:error, :invalid_fb_jid}
    end
  end

  defp read_interop_jid(data) do
    with {:ok, user_tag, rest} <- take_byte(data),
         {:ok, user, <<device::16, integrator::16, rest::binary>>} <- read_string(user_tag, rest) do
      {server, rest} =
        with {:ok, server_tag, server_rest} <- take_byte(rest),
             {:ok, server, server_rest} <- read_string(server_tag, server_rest) do
          {server, server_rest}
        else
          _invalid -> {"interop", rest}
        end

      {:ok, "#{integrator}-#{user}:#{device}@#{server}", rest}
    else
      _invalid -> {:error, :invalid_interop_jid}
    end
  end

  defp read_packed(tag, <<length, data::binary>>) do
    byte_count = length &&& 127

    if byte_size(data) < byte_count do
      {:error, :end_of_stream}
    else
      <<packed::binary-size(byte_count), rest::binary>> = data

      decoded =
        for <<first::4, second::4 <- packed>>, into: <<>> do
          <<unpack_character(first, tag), unpack_character(second, tag)>>
        end

      decoded =
        if (length &&& 128) != 0,
          do: binary_part(decoded, 0, byte_size(decoded) - 1),
          else: decoded

      {:ok, decoded, rest}
    end
  end

  defp read_packed(_tag, _data), do: {:error, :end_of_stream}

  defp unpack_character(value, _tag) when value in 0..9, do: ?0 + value
  defp unpack_character(10, @nibble_8), do: ?-
  defp unpack_character(11, @nibble_8), do: ?.
  defp unpack_character(value, @hex_8) when value in 10..15, do: ?A + value - 10
  defp unpack_character(15, @nibble_8), do: 0

  defp read_list_size(@list_empty, rest), do: {:ok, 0, rest}
  defp read_list_size(@list_8, <<size, rest::binary>>), do: {:ok, size, rest}
  defp read_list_size(@list_16, <<size::16, rest::binary>>), do: {:ok, size, rest}
  defp read_list_size(_tag, _data), do: {:error, :invalid_list_tag}

  defp read_sized_binary(data, bytes, type \\ :integer)

  defp read_sized_binary(data, bytes, :integer) do
    if byte_size(data) < bytes do
      {:error, :end_of_stream}
    else
      <<length::unsigned-big-integer-size(bytes)-unit(8), rest::binary>> = data

      if byte_size(rest) >= length do
        <<value::binary-size(length), rest::binary>> = rest
        {:ok, value, rest}
      else
        {:error, :end_of_stream}
      end
    end
  end

  defp read_sized_binary(<<first, second, third, rest::binary>>, 3, :int20) do
    length = ((first &&& 15) <<< 16) + (second <<< 8) + third

    if byte_size(rest) >= length do
      <<value::binary-size(length), rest::binary>> = rest
      {:ok, value, rest}
    else
      {:error, :end_of_stream}
    end
  end

  defp read_sized_binary(_data, _bytes, _type), do: {:error, :end_of_stream}

  defp take_byte(<<byte, rest::binary>>), do: {:ok, byte, rest}
  defp take_byte(<<>>), do: {:error, :end_of_stream}
end
