defmodule Baileys.NoiseTest do
  use ExUnit.Case, async: true

  alias Baileys.Noise

  test "uses the 32-byte Noise protocol name directly as the initial hash" do
    public_key = :binary.copy(<<1>>, 32)
    state = Noise.new(public_key)
    mode = "Noise_XX_25519_AESGCM_SHA256\0\0\0\0"

    expected =
      :crypto.hash(:sha256, :crypto.hash(:sha256, mode <> <<87, 65, 6, 3>>) <> public_key)

    assert state.hash == expected
  end

  test "buffers fragmented handshake frames" do
    state = %{Noise.new(:crypto.strong_rand_bytes(32)) | intro: "", intro_sent?: true}
    {frame, state} = Noise.encode_frame(state, "hello")
    split = div(byte_size(frame), 2)
    <<first::binary-size(split), second::binary>> = frame

    assert {:ok, [], state} = Noise.push(state, first)
    assert {:ok, ["hello"], _state} = Noise.push(state, second)
  end

  test "encrypts and decrypts transport frames with independent counters" do
    base = Noise.new(:crypto.strong_rand_bytes(32)) |> Noise.mix_key("shared") |> Noise.finish()
    sender = %{base | intro: "", intro_sent?: true}

    receiver = %{
      base
      | enc_key: base.dec_key,
        dec_key: base.enc_key,
        intro: "",
        intro_sent?: true
    }

    {frame, sender} = Noise.encode_frame(sender, "one")
    {frame2, _sender} = Noise.encode_frame(sender, "two")

    assert {:ok, ["one", "two"], _receiver} = Noise.push(receiver, frame <> frame2)
  end
end
