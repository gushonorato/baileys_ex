defmodule Baileys.Signal.SenderKeyTest do
  use ExUnit.Case, async: true

  alias Baileys.Signal.SenderKey

  test "processes a distribution and decrypts a signed group message" do
    sending = sending_record(1)
    distribution = SenderKey.distribution(sending)
    assert {:ok, receiving} = SenderKey.process_distribution(nil, distribution)

    assert {:ok, ciphertext, _sending} = SenderKey.encrypt(sending, "group fixture")
    assert {:ok, "group fixture", _receiving} = SenderKey.decrypt(receiving, ciphertext)
  end

  test "caches skipped keys once and rejects replay" do
    sending = sending_record(2)
    assert {:ok, receiving} = SenderKey.process_distribution(nil, SenderKey.distribution(sending))

    assert {:ok, first, sending} = SenderKey.encrypt(sending, "first")
    assert {:ok, _second, sending} = SenderKey.encrypt(sending, "second")
    assert {:ok, third, _sending} = SenderKey.encrypt(sending, "third")

    assert {:ok, "third", receiving} = SenderKey.decrypt(receiving, third)
    assert {:ok, "first", receiving} = SenderKey.decrypt(receiving, first)
    assert {:error, :old_sender_key_message} = SenderKey.decrypt(receiving, first)
  end

  test "bounds future iterations and keeps the record unchanged on invalid signatures" do
    sending = sending_record(3)
    assert {:ok, receiving} = SenderKey.process_distribution(nil, SenderKey.distribution(sending))
    assert {:ok, ciphertext, _sending} = SenderKey.encrypt(sending, "signed")

    <<prefix::binary-size(byte_size(ciphertext) - 1), last>> = ciphertext
    corrupted = prefix <> <<Bitwise.bxor(last, 1)>>
    assert {:error, :invalid_sender_key_signature} = SenderKey.decrypt(receiving, corrupted)

    far_state = put_in(sending.states, [put_in(hd(sending.states).chain_key.iteration, 2_001)])
    assert {:ok, far_ciphertext, _record} = SenderKey.encrypt(far_state, "too far")
    assert {:error, :sender_key_message_too_far} = SenderKey.decrypt(receiving, far_ciphertext)
  end

  test "retains only the newest five distribution states" do
    receiving =
      Enum.reduce(1..6, nil, fn id, record ->
        assert {:ok, record} =
                 SenderKey.process_distribution(
                   record,
                   SenderKey.distribution(sending_record(id))
                 )

        record
      end)

    assert Enum.map(receiving.states, & &1.key_id) == [2, 3, 4, 5, 6]
  end

  test "uses wire group and author identity in record keys" do
    assert SenderKey.record_key("fixture-group@g.us", "remote-user:3@s.whatsapp.net") ==
             "fixture-group@g.us::remote-user::3"

    assert SenderKey.record_key("fixture-group@g.us", "remote-lid:4@lid") ==
             "fixture-group@g.us::remote-lid_1::4"
  end

  defp sending_record(id) do
    private = :binary.copy(<<id>>, 32)
    {public, ^private} = :crypto.generate_key(:ecdh, :x25519, private)

    SenderKey.new_record(
      SenderKey.new_state(id, 0, :binary.copy(<<id + 10>>, 32), %{
        public: public,
        private: private
      })
    )
  end
end
