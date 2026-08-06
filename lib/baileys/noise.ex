defmodule Baileys.Noise do
  @moduledoc false

  alias Baileys.Crypto

  @mode "Noise_XX_25519_AESGCM_SHA256\0\0\0\0"
  @header <<87, 65, 6, 3>>

  @type phase :: :handshake | :transport
  @type t :: %__MODULE__{
          phase: phase(),
          hash: binary(),
          salt: binary(),
          enc_key: binary(),
          dec_key: binary(),
          counter: non_neg_integer(),
          read_counter: non_neg_integer(),
          write_counter: non_neg_integer(),
          intro: binary(),
          intro_sent?: boolean(),
          buffer: binary()
        }

  defstruct [
    :hash,
    :salt,
    :enc_key,
    :dec_key,
    :intro,
    phase: :handshake,
    counter: 0,
    read_counter: 0,
    write_counter: 0,
    intro_sent?: false,
    buffer: ""
  ]

  def new(ephemeral_public_key, routing_info \\ nil)
      when byte_size(ephemeral_public_key) == 32 do
    hash = if byte_size(@mode) == 32, do: @mode, else: Crypto.sha256(@mode)
    intro = intro_header(routing_info)

    %__MODULE__{
      hash: hash,
      salt: hash,
      enc_key: hash,
      dec_key: hash,
      intro: intro
    }
    |> authenticate(@header)
    |> authenticate(ephemeral_public_key)
  end

  def authenticate(%__MODULE__{phase: :handshake} = state, data) do
    %{state | hash: Crypto.sha256(state.hash <> data)}
  end

  def authenticate(%__MODULE__{} = state, _data), do: state

  def mix_key(%__MODULE__{phase: :handshake} = state, data) do
    <<salt::binary-size(32), key::binary-size(32)>> =
      Crypto.hkdf(data, 64, salt: state.salt, info: "")

    %{state | salt: salt, enc_key: key, dec_key: key, counter: 0}
  end

  def encrypt(%__MODULE__{phase: :handshake} = state, plaintext) do
    ciphertext =
      Crypto.aes_gcm_encrypt(plaintext, state.enc_key, nonce(state.counter), state.hash)

    state = state |> Map.update!(:counter, &(&1 + 1)) |> authenticate(ciphertext)
    {ciphertext, state}
  end

  def encrypt(%__MODULE__{phase: :transport} = state, plaintext) do
    ciphertext = Crypto.aes_gcm_encrypt(plaintext, state.enc_key, nonce(state.write_counter), "")
    {ciphertext, %{state | write_counter: state.write_counter + 1}}
  end

  def decrypt(%__MODULE__{phase: :handshake} = state, ciphertext) do
    with {:ok, plaintext} <-
           Crypto.aes_gcm_decrypt(ciphertext, state.dec_key, nonce(state.counter), state.hash) do
      state = state |> Map.update!(:counter, &(&1 + 1)) |> authenticate(ciphertext)
      {:ok, plaintext, state}
    end
  end

  def decrypt(%__MODULE__{phase: :transport} = state, ciphertext) do
    with {:ok, plaintext} <-
           Crypto.aes_gcm_decrypt(ciphertext, state.dec_key, nonce(state.read_counter), "") do
      {:ok, plaintext, %{state | read_counter: state.read_counter + 1}}
    end
  end

  def finish(%__MODULE__{phase: :handshake} = state) do
    <<write_key::binary-size(32), read_key::binary-size(32)>> =
      Crypto.hkdf("", 64, salt: state.salt, info: "")

    %{
      state
      | phase: :transport,
        enc_key: write_key,
        dec_key: read_key,
        read_counter: 0,
        write_counter: 0
    }
  end

  def encode_frame(%__MODULE__{} = state, plaintext) do
    {payload, state} =
      if state.phase == :transport do
        encrypt(state, plaintext)
      else
        {plaintext, state}
      end

    intro = if state.intro_sent?, do: "", else: state.intro
    size = byte_size(payload)
    frame = <<intro::binary, size::24, payload::binary>>
    {frame, %{state | intro_sent?: true}}
  end

  def push(%__MODULE__{} = state, data) when is_binary(data) do
    parse_frames(%{state | buffer: state.buffer <> data}, [])
  end

  defp parse_frames(%__MODULE__{buffer: buffer} = state, frames) when byte_size(buffer) < 3 do
    {:ok, Enum.reverse(frames), state}
  end

  defp parse_frames(%__MODULE__{buffer: <<size::24, rest::binary>>} = state, frames)
       when byte_size(rest) >= size do
    <<payload::binary-size(size), remaining::binary>> = rest
    state = %{state | buffer: remaining}

    case state.phase do
      :handshake ->
        parse_frames(state, [payload | frames])

      :transport ->
        with {:ok, plaintext, state} <- decrypt(state, payload) do
          parse_frames(state, [plaintext | frames])
        end
    end
  end

  defp parse_frames(state, frames), do: {:ok, Enum.reverse(frames), state}

  defp nonce(counter), do: <<0::64, counter::32>>

  defp intro_header(nil), do: @header

  defp intro_header(routing_info) when is_binary(routing_info) do
    <<"ED", 0, 1, byte_size(routing_info)::24, routing_info::binary, @header::binary>>
  end
end
