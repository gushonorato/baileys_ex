defmodule Baileys.Store.S3.Encryption do
  @moduledoc """
  Behaviour for client-side encryption of S3 session payloads.

  The context passed to callbacks is the full S3 object key. Implementations
  should authenticate it along with the ciphertext so an encrypted session
  cannot be moved to another key undetected.
  """

  @type state :: term()

  @callback init(keyword()) :: {:ok, state()} | {:error, term()}
  @callback encrypt(state(), context :: binary(), plaintext :: binary()) ::
              {:ok, ciphertext :: binary()} | {:error, term()}
  @callback decrypt(state(), context :: binary(), ciphertext :: binary()) ::
              {:ok, plaintext :: binary()} | {:error, term()}
end

defmodule Baileys.Store.S3.Encryption.AESGCM do
  @moduledoc """
  AES-256-GCM client-side encryption for S3 session payloads.

  Configure either a raw 32-byte `:key` or a Base64-encoded 32-byte
  `:key_base64`. A fresh 96-bit nonce is generated for every upload.
  """

  @behaviour Baileys.Store.S3.Encryption

  @magic "BEXS3"
  @version 1
  @nonce_bytes 12
  @tag_bytes 16

  @impl true
  def init(options) do
    with {:ok, key} <- key(options),
         true <- byte_size(key) == 32 do
      {:ok, key}
    else
      false -> {:error, :invalid_key}
      {:error, _reason} = error -> error
    end
  end

  @impl true
  def encrypt(key, context, plaintext)
      when is_binary(key) and is_binary(context) and is_binary(plaintext) do
    nonce = :crypto.strong_rand_bytes(@nonce_bytes)

    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(:aes_256_gcm, key, nonce, plaintext, context, true)

    {:ok, <<@magic, @version, nonce::binary, tag::binary, ciphertext::binary>>}
  rescue
    _error -> {:error, :encryption_failed}
  end

  @impl true
  def decrypt(
        key,
        context,
        <<@magic, @version, nonce::binary-size(@nonce_bytes), tag::binary-size(@tag_bytes),
          ciphertext::binary>>
      )
      when is_binary(key) and is_binary(context) do
    case :crypto.crypto_one_time_aead(
           :aes_256_gcm,
           key,
           nonce,
           ciphertext,
           context,
           tag,
           false
         ) do
      :error -> {:error, :decryption_failed}
      plaintext when is_binary(plaintext) -> {:ok, plaintext}
    end
  rescue
    _error -> {:error, :decryption_failed}
  end

  def decrypt(_key, _context, _ciphertext), do: {:error, :invalid_ciphertext}

  defp key(options) do
    case {Keyword.fetch(options, :key), Keyword.fetch(options, :key_base64)} do
      {{:ok, key}, :error} when is_binary(key) ->
        {:ok, key}

      {:error, {:ok, encoded}} when is_binary(encoded) ->
        case Base.decode64(encoded) do
          {:ok, key} -> {:ok, key}
          :error -> {:error, :invalid_key}
        end

      {:error, :error} ->
        {:error, :key_required}

      _invalid ->
        {:error, :invalid_key}
    end
  end
end
