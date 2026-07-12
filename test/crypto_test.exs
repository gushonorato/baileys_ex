defmodule BaileysExo.CryptoTest do
  use ExUnit.Case, async: true

  alias BaileysExo.Crypto
  alias BaileysExo.Crypto.XEdDSA

  test "implements RFC 5869 HKDF-SHA256 vector 1" do
    input = :binary.copy(<<0x0B>>, 22)
    salt = Base.decode16!("000102030405060708090A0B0C")
    info = Base.decode16!("F0F1F2F3F4F5F6F7F8F9")

    expected =
      Base.decode16!(
        "3CB25F25FAACD57A90434F64D0362F2A" <>
          "2D2D0A90CF1A5A4C5DB02D56ECC4C5BF" <>
          "34007208D5B887185865"
      )

    assert Crypto.hkdf(input, 42, salt: salt, info: info) == expected
  end

  test "derives equal X25519 shared keys" do
    alice = Crypto.generate_x25519_key_pair()
    bob = Crypto.generate_x25519_key_pair()

    assert Crypto.x25519(alice.private, bob.public) ==
             Crypto.x25519(bob.private, alice.public)
  end

  test "round trips AES-GCM and rejects a modified tag" do
    key = :crypto.strong_rand_bytes(32)
    iv = :crypto.strong_rand_bytes(12)
    encrypted = Crypto.aes_gcm_encrypt("message", key, iv, "aad")

    assert Crypto.aes_gcm_decrypt(encrypted, key, iv, "aad") == {:ok, "message"}

    <<prefix::binary-size(byte_size(encrypted) - 1), last>> = encrypted

    assert Crypto.aes_gcm_decrypt(prefix <> <<Bitwise.bxor(last, 1)>>, key, iv, "aad") ==
             {:error, :authentication_failed}
  end

  test "round trips padded AES-CBC" do
    key = :crypto.strong_rand_bytes(32)
    iv = :crypto.strong_rand_bytes(16)
    encrypted = Crypto.aes_cbc_encrypt("message", key, iv)

    assert Crypto.aes_cbc_decrypt(encrypted, key, iv) == {:ok, "message"}
  end

  test "signs and verifies XEd25519 messages with X25519 keys" do
    key_pair = Crypto.generate_x25519_key_pair()
    signature = XEdDSA.sign("message", key_pair.private)

    assert byte_size(signature) == 64
    assert XEdDSA.verify("message", signature, key_pair.public)
    refute XEdDSA.verify("modified", signature, key_pair.public)
  end
end
