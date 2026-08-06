defmodule Baileys.SignalTest do
  use ExUnit.Case, async: true

  alias Baileys.Auth.Credentials
  alias Baileys.Crypto
  alias Baileys.Signal.{SessionBuilder, SessionCipher}

  test "establishes X3DH and decrypts the first pre-key message" do
    alice = Credentials.new()
    bob = Credentials.new()
    bob_pre_key = Crypto.generate_x25519_key_pair()
    bob = %{bob | pre_keys: %{7 => bob_pre_key}}

    bundle = %{
      registration_id: bob.registration_id,
      identity_key: <<5, bob.signed_identity_key.public::binary>>,
      signed_pre_key: %{
        key_id: bob.signed_pre_key.key_id,
        public: <<5, bob.signed_pre_key.key_pair.public::binary>>,
        signature: bob.signed_pre_key.signature
      },
      pre_key: %{key_id: 7, public: <<5, bob_pre_key.public::binary>>}
    }

    assert {:ok, alice_record} =
             SessionBuilder.init_outgoing(nil, bundle, alice.signed_identity_key)

    assert {:ok, :pkmsg, ciphertext, _alice_record} =
             SessionCipher.encrypt(
               alice_record,
               "hello",
               alice.signed_identity_key,
               alice.registration_id
             )

    assert {:ok, "hello", _bob_record, 7} =
             SessionCipher.decrypt_pre_key(nil, ciphertext, bob)
  end
end
