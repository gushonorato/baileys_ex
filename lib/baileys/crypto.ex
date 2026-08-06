defmodule Baileys.Crypto do
  @moduledoc false

  @type key_pair :: %{public: binary(), private: binary()}

  @spec generate_x25519_key_pair() :: key_pair()
  def generate_x25519_key_pair do
    {public, private} = :crypto.generate_key(:ecdh, :x25519)
    %{public: public, private: private}
  end

  @spec x25519(binary(), binary()) :: binary()
  def x25519(private, public) when byte_size(private) == 32 and byte_size(public) == 32 do
    :crypto.compute_key(:ecdh, public, private, :x25519)
  end

  def sha256(data), do: :crypto.hash(:sha256, data)
  def hmac_sha256(key, data), do: :crypto.mac(:hmac, :sha256, key, data)

  @spec hkdf(binary(), non_neg_integer(), keyword()) :: binary()
  def hkdf(input, length, options \\ []) when length >= 0 do
    salt = Keyword.get(options, :salt, <<0::256>>)
    info = Keyword.get(options, :info, "")
    pseudorandom_key = hmac_sha256(salt, input)
    expand_hkdf(pseudorandom_key, info, length, 1, "", "")
  end

  def aes_gcm_encrypt(plaintext, key, iv, aad \\ "") do
    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, plaintext, aad, 16, true)

    ciphertext <> tag
  end

  def aes_gcm_decrypt(ciphertext_and_tag, key, iv, aad \\ "")

  def aes_gcm_decrypt(ciphertext_and_tag, key, iv, aad)
      when byte_size(ciphertext_and_tag) >= 16 do
    ciphertext_size = byte_size(ciphertext_and_tag) - 16
    <<ciphertext::binary-size(ciphertext_size), tag::binary-size(16)>> = ciphertext_and_tag

    case :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, ciphertext, aad, tag, false) do
      :error -> {:error, :authentication_failed}
      plaintext -> {:ok, plaintext}
    end
  end

  def aes_gcm_decrypt(_ciphertext, _key, _iv, _aad), do: {:error, :invalid_ciphertext}

  def aes_ctr(data, key, iv) do
    :crypto.crypto_one_time(:aes_256_ctr, key, iv, data, true)
  end

  def aes_cbc_encrypt(plaintext, key, iv) do
    :crypto.crypto_one_time(:aes_256_cbc, key, iv, pkcs7_pad(plaintext, 16), true)
  end

  def aes_cbc_decrypt(ciphertext, key, iv) do
    plaintext = :crypto.crypto_one_time(:aes_256_cbc, key, iv, ciphertext, false)
    pkcs7_unpad(plaintext, 16)
  end

  def pbkdf2_sha256(password, salt, iterations, length) do
    :crypto.pbkdf2_hmac(:sha256, password, salt, iterations, length)
  end

  def pkcs7_pad(data, block_size) do
    padding_size = block_size - rem(byte_size(data), block_size)
    data <> :binary.copy(<<padding_size>>, padding_size)
  end

  def pkcs7_unpad(data, block_size) when byte_size(data) > 0 do
    padding_size = :binary.last(data)

    cond do
      padding_size < 1 or padding_size > block_size or padding_size > byte_size(data) ->
        {:error, :invalid_padding}

      binary_part(data, byte_size(data) - padding_size, padding_size) !=
          :binary.copy(<<padding_size>>, padding_size) ->
        {:error, :invalid_padding}

      true ->
        {:ok, binary_part(data, 0, byte_size(data) - padding_size)}
    end
  end

  def pkcs7_unpad(_data, _block_size), do: {:error, :invalid_padding}

  defp expand_hkdf(_key, _info, 0, _counter, _previous, output), do: output

  defp expand_hkdf(key, info, remaining, counter, previous, output) when counter <= 255 do
    block = hmac_sha256(key, previous <> info <> <<counter>>)
    take = min(remaining, byte_size(block))

    expand_hkdf(
      key,
      info,
      remaining - take,
      counter + 1,
      block,
      output <> binary_part(block, 0, take)
    )
  end
end
