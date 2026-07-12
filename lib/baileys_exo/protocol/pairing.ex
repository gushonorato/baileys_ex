defmodule BaileysExo.Protocol.Pairing do
  @moduledoc false

  alias BaileysExo.Auth.Credentials
  alias BaileysExo.Binary.{Node, NodeUtils}
  alias BaileysExo.{Crypto, JID}
  alias BaileysExo.Crypto.XEdDSA
  alias BaileysExo.Proto.{ADVDeviceIdentity, ADVSignedDeviceIdentity}
  alias BaileysExo.Proto.ADVSignedDeviceIdentityHMAC

  @account_signature_prefix <<6, 0>>
  @device_signature_prefix <<6, 1>>
  @hosted_account_signature_prefix <<6, 5>>
  @crockford_alphabet "123456789ABCDEFGHJKLMNPQRSTVWXYZ"

  def request_code(%Credentials{} = credentials, phone, custom_code \\ nil) do
    code = custom_code || random_pairing_code()

    with :ok <- validate_code(code),
         {:ok, phone} <- normalize_phone(phone) do
      salt = :crypto.strong_rand_bytes(32)
      iv = :crypto.strong_rand_bytes(16)
      key = Crypto.pbkdf2_sha256(code, salt, 131_072, 32)
      wrapped = Crypto.aes_ctr(credentials.pairing_ephemeral_key.public, key, iv)
      jid = JID.encode(phone, "s.whatsapp.net")

      node = %Node{
        tag: "iq",
        attrs: %{
          "to" => "s.whatsapp.net",
          "type" => "set",
          "id" => message_tag(),
          "xmlns" => "md"
        },
        content: [
          %Node{
            tag: "link_code_companion_reg",
            attrs: %{
              "jid" => jid,
              "stage" => "companion_hello",
              "should_show_push_notification" => "true"
            },
            content: [
              %Node{
                tag: "link_code_pairing_wrapped_companion_ephemeral_pub",
                content: salt <> iv <> wrapped
              },
              %Node{tag: "companion_server_auth_key_pub", content: credentials.noise_key.public},
              %Node{tag: "companion_platform_id", content: {:text, "7"}},
              %Node{tag: "companion_platform_display", content: {:text, "Desktop (Mac OS)"}},
              %Node{tag: "link_code_pairing_nonce", content: {:text, "0"}}
            ]
          }
        ]
      }

      credentials = %{credentials | pairing_code: code, me: %{id: jid, name: "~"}}
      {:ok, code, node, credentials}
    end
  end

  def finish_code(%Node{} = notification, %Credentials{pairing_code: code} = credentials)
      when is_binary(code) do
    registration = NodeUtils.child(notification, "link_code_companion_reg")

    with %Node{} <- registration,
         {:ok, reference} <- child_buffer(registration, "link_code_pairing_ref"),
         {:ok, primary_identity} <- child_buffer(registration, "primary_identity_pub"),
         {:ok, wrapped_primary} <-
           child_buffer(registration, "link_code_pairing_wrapped_primary_ephemeral_pub"),
         {:ok, primary_ephemeral} <- unwrap_primary_key(wrapped_primary, code) do
      companion_shared =
        Crypto.x25519(credentials.pairing_ephemeral_key.private, primary_ephemeral)

      random = :crypto.strong_rand_bytes(32)
      salt = :crypto.strong_rand_bytes(32)

      encryption_key =
        Crypto.hkdf(companion_shared, 32,
          salt: salt,
          info: "link_code_pairing_key_bundle_encryption_key"
        )

      payload = credentials.signed_identity_key.public <> primary_identity <> random
      iv = :crypto.strong_rand_bytes(12)
      encrypted_payload = salt <> iv <> Crypto.aes_gcm_encrypt(payload, encryption_key, iv)
      identity_shared = Crypto.x25519(credentials.signed_identity_key.private, primary_identity)

      adv_secret =
        Crypto.hkdf(companion_shared <> identity_shared <> random, 32, info: "adv_secret")

      node = %Node{
        tag: "iq",
        attrs: %{
          "to" => "s.whatsapp.net",
          "type" => "set",
          "id" => message_tag(),
          "xmlns" => "md"
        },
        content: [
          %Node{
            tag: "link_code_companion_reg",
            attrs: %{"jid" => credentials.me.id, "stage" => "companion_finish"},
            content: [
              %Node{tag: "link_code_pairing_wrapped_key_bundle", content: encrypted_payload},
              %Node{
                tag: "companion_identity_public",
                content: credentials.signed_identity_key.public
              },
              %Node{tag: "link_code_pairing_ref", content: reference}
            ]
          }
        ]
      }

      {:ok, node, %{credentials | adv_secret_key: adv_secret}}
    else
      nil -> {:error, :invalid_pairing_notification}
      {:error, _reason} = error -> error
    end
  end

  def finish_code(_notification, _credentials), do: {:error, :pairing_code_not_requested}

  def pair_success(%Node{} = stanza, %Credentials{} = credentials) do
    pair_success = NodeUtils.child(stanza, "pair-success")

    with %Node{} <- pair_success,
         %Node{} = identity_node <- NodeUtils.child(pair_success, "device-identity"),
         %Node{} = device_node <- NodeUtils.child(pair_success, "device"),
         true <- is_binary(identity_node.content),
         hmac_identity <- ADVSignedDeviceIdentityHMAC.decode(identity_node.content),
         :ok <- verify_hmac_identity(hmac_identity, credentials.adv_secret_key),
         account <- ADVSignedDeviceIdentity.decode(hmac_identity.details),
         device_identity <- ADVDeviceIdentity.decode(account.details),
         :ok <- verify_account(account, device_identity, credentials.signed_identity_key.public),
         account <- sign_device(account, device_identity, credentials.signed_identity_key) do
      encoded_account = Protobuf.encode(%{account | accountSignatureKey: nil})

      reply = %Node{
        tag: "iq",
        attrs: %{"to" => "s.whatsapp.net", "type" => "result", "id" => stanza.attrs["id"]},
        content: [
          %Node{
            tag: "pair-device-sign",
            content: [
              %Node{
                tag: "device-identity",
                attrs: %{"key-index" => Integer.to_string(device_identity.keyIndex)},
                content: encoded_account
              }
            ]
          }
        ]
      }

      business = NodeUtils.child(pair_success, "biz")
      platform = NodeUtils.child(pair_success, "platform")

      credentials = %{
        credentials
        | account: account,
          registered?: true,
          me: %{
            id: device_node.attrs["jid"],
            lid: device_node.attrs["lid"],
            name: business && business.attrs["name"]
          },
          platform: platform && platform.attrs["name"]
      }

      {:ok, reply, credentials}
    else
      nil -> {:error, :invalid_pair_success}
      false -> {:error, :invalid_pair_success}
      {:error, _reason} = error -> error
    end
  rescue
    error -> {:error, error}
  end

  defp verify_hmac_identity(identity, adv_secret) do
    prefix = if identity.accountType == :HOSTED, do: @hosted_account_signature_prefix, else: ""
    expected = Crypto.hmac_sha256(adv_secret, prefix <> identity.details)

    if byte_size(identity.hmac) == byte_size(expected) and
         :crypto.hash_equals(identity.hmac, expected) do
      :ok
    else
      {:error, :invalid_account_hmac}
    end
  end

  defp verify_account(account, device_identity, local_identity_public) do
    prefix =
      if device_identity.deviceType == :HOSTED,
        do: @hosted_account_signature_prefix,
        else: @account_signature_prefix

    message = prefix <> account.details <> local_identity_public

    if XEdDSA.verify(message, account.accountSignature, account.accountSignatureKey) do
      :ok
    else
      {:error, :invalid_account_signature}
    end
  end

  defp sign_device(account, _device_identity, identity_key) do
    message =
      @device_signature_prefix <>
        account.details <> identity_key.public <> account.accountSignatureKey

    %{account | deviceSignature: XEdDSA.sign(message, identity_key.private)}
  end

  defp unwrap_primary_key(
         <<salt::binary-size(32), iv::binary-size(16), payload::binary-size(32)>>,
         code
       ) do
    key = Crypto.pbkdf2_sha256(code, salt, 131_072, 32)
    {:ok, Crypto.aes_ctr(payload, key, iv)}
  end

  defp unwrap_primary_key(_wrapped, _code), do: {:error, :invalid_wrapped_primary_key}

  defp child_buffer(node, tag) do
    case NodeUtils.child(node, tag) do
      %Node{content: content} when is_binary(content) -> {:ok, content}
      _missing -> {:error, {:missing_pairing_field, tag}}
    end
  end

  defp validate_code(code) when is_binary(code) and byte_size(code) == 8 do
    if code =~ ~r/^[A-Z0-9]{8}$/, do: :ok, else: {:error, :invalid_pairing_code}
  end

  defp validate_code(_code), do: {:error, :invalid_pairing_code}

  defp normalize_phone(phone) do
    digits = String.replace(phone, ~r/\D/, "")
    if byte_size(digits) in 8..15, do: {:ok, digits}, else: {:error, :invalid_phone}
  end

  defp random_pairing_code do
    <<value::unsigned-big-integer-size(40)>> = :crypto.strong_rand_bytes(5)

    for shift <- 35..0//-5, into: "" do
      index = Bitwise.band(Bitwise.bsr(value, shift), 31)
      <<:binary.at(@crockford_alphabet, index)>>
    end
  end

  defp message_tag do
    "#{System.system_time(:second)}.#{System.unique_integer([:positive])}"
  end
end
