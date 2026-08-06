defmodule Baileys.AppState.Crypto do
  @moduledoc false

  import Bitwise

  alias Baileys.Crypto, as: CoreCrypto

  @mutation_info "WhatsApp Mutation Keys"
  @lt_hash_info "WhatsApp Patch Integrity"
  @lt_hash_size 128
  @uint64_max 0xFFFFFFFFFFFFFFFF

  @type mutation_keys :: %{
          index_key: binary(),
          value_encryption_key: binary(),
          value_mac_key: binary(),
          snapshot_mac_key: binary(),
          patch_mac_key: binary()
        }

  @spec derive_keys(binary()) :: mutation_keys()
  def derive_keys(key_data) when is_binary(key_data) do
    <<index_key::binary-size(32), value_encryption_key::binary-size(32),
      value_mac_key::binary-size(32), snapshot_mac_key::binary-size(32),
      patch_mac_key::binary-size(32)>> =
      CoreCrypto.hkdf(key_data, 160, info: @mutation_info)

    %{
      index_key: index_key,
      value_encryption_key: value_encryption_key,
      value_mac_key: value_mac_key,
      snapshot_mac_key: snapshot_mac_key,
      patch_mac_key: patch_mac_key
    }
  end

  @spec uint64_be(non_neg_integer()) :: <<_::64>>
  def uint64_be(value) when is_integer(value) and value >= 0 and value <= @uint64_max do
    <<value::unsigned-big-64>>
  end

  @spec value_mac(:SET | :REMOVE, binary(), binary(), binary()) :: binary()
  def value_mac(operation, encrypted_value, key_id, key)
      when is_binary(encrypted_value) and is_binary(key_id) and is_binary(key) do
    key_data = <<operation_byte(operation)>> <> key_id
    input = key_data <> encrypted_value <> uint64_be(byte_size(key_data))
    binary_part(:crypto.mac(:hmac, :sha512, key, input), 0, 32)
  end

  @spec index_mac(binary(), binary()) :: binary()
  def index_mac(index_json, key) when is_binary(index_json) and is_binary(key) do
    CoreCrypto.hmac_sha256(key, index_json)
  end

  @spec snapshot_mac(binary(), non_neg_integer(), binary(), binary()) :: binary()
  def snapshot_mac(lt_hash, version, collection, key)
      when byte_size(lt_hash) == @lt_hash_size and is_binary(collection) and is_binary(key) do
    CoreCrypto.hmac_sha256(key, lt_hash <> uint64_be(version) <> collection)
  end

  @spec patch_mac(binary(), [binary()], non_neg_integer(), binary(), binary()) :: binary()
  def patch_mac(snapshot_mac, value_macs, version, collection, key)
      when is_binary(snapshot_mac) and is_list(value_macs) and is_binary(collection) and
             is_binary(key) do
    data = IO.iodata_to_binary([snapshot_mac, value_macs, uint64_be(version), collection])
    CoreCrypto.hmac_sha256(key, data)
  end

  @spec lt_hash_add(binary(), binary() | [binary()]) :: binary()
  def lt_hash_add(hash, value_macs) when is_list(value_macs) do
    Enum.reduce(value_macs, hash, &lt_hash_add(&2, &1))
  end

  def lt_hash_add(hash, value_mac)
      when byte_size(hash) == @lt_hash_size and is_binary(value_mac) do
    pointwise(hash, expand_lt_hash_value(value_mac), :add)
  end

  @spec lt_hash_subtract(binary(), binary() | [binary()]) :: binary()
  def lt_hash_subtract(hash, value_macs) when is_list(value_macs) do
    Enum.reduce(value_macs, hash, &lt_hash_subtract(&2, &1))
  end

  def lt_hash_subtract(hash, value_mac)
      when byte_size(hash) == @lt_hash_size and is_binary(value_mac) do
    pointwise(hash, expand_lt_hash_value(value_mac), :subtract)
  end

  @spec decrypt_value(binary(), binary()) :: {:ok, binary()} | {:error, atom()}
  def decrypt_value(
        <<iv::binary-size(16), ciphertext::binary>>,
        key
      )
      when byte_size(key) == 32 and byte_size(ciphertext) > 0 and
             rem(byte_size(ciphertext), 16) == 0 do
    CoreCrypto.aes_cbc_decrypt(ciphertext, key, iv)
  end

  def decrypt_value(_encrypted_value, _key), do: {:error, :invalid_encrypted_value}

  @spec secure_compare(binary(), binary()) :: boolean()
  def secure_compare(left, right)
      when is_binary(left) and is_binary(right) and byte_size(left) == byte_size(right) do
    :crypto.hash_equals(left, right)
  end

  def secure_compare(left, right) when is_binary(left) and is_binary(right), do: false

  defp operation_byte(:SET), do: 0x01
  defp operation_byte(:REMOVE), do: 0x02

  defp expand_lt_hash_value(value_mac) do
    CoreCrypto.hkdf(value_mac, @lt_hash_size, info: @lt_hash_info)
  end

  defp pointwise(left, right, operation) do
    pointwise(left, right, operation, [])
  end

  defp pointwise(<<>>, <<>>, _operation, result) do
    result
    |> Enum.reverse()
    |> IO.iodata_to_binary()
  end

  defp pointwise(
         <<left::unsigned-little-16, left_rest::binary>>,
         <<right::unsigned-little-16, right_rest::binary>>,
         operation,
         result
       ) do
    value =
      case operation do
        :add -> left + right
        :subtract -> left - right
      end

    pointwise(
      left_rest,
      right_rest,
      operation,
      [<<band(value, 0xFFFF)::unsigned-little-16>> | result]
    )
  end
end
