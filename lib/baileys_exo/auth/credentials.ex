defmodule BaileysExo.Auth.Credentials do
  @moduledoc false

  alias BaileysExo.Crypto
  alias BaileysExo.Crypto.XEdDSA

  @type t :: %__MODULE__{}

  defstruct [
    :noise_key,
    :pairing_ephemeral_key,
    :signed_identity_key,
    :signed_pre_key,
    :registration_id,
    :adv_secret_key,
    :me,
    :account,
    :platform,
    :routing_info,
    :pairing_code,
    registered?: false,
    next_pre_key_id: 1,
    first_unuploaded_pre_key_id: 1,
    sessions: %{},
    sender_keys: %{},
    pre_keys: %{},
    lid_mappings: %{},
    account_settings: %{},
    privacy_tokens: %{},
    pending_app_state_sync: [],
    history_sync_progress: %{},
    pending_history_sync: [],
    app_state_sync_keys: %{},
    app_state_collections: %{},
    my_app_state_key_id: nil
  ]

  def new do
    identity = Crypto.generate_x25519_key_pair()
    pre_key = Crypto.generate_x25519_key_pair()

    signed_pre_key = %{
      key_pair: pre_key,
      key_id: 1,
      signature: XEdDSA.sign(<<5, pre_key.public::binary>>, identity.private)
    }

    %__MODULE__{
      noise_key: Crypto.generate_x25519_key_pair(),
      pairing_ephemeral_key: Crypto.generate_x25519_key_pair(),
      signed_identity_key: identity,
      signed_pre_key: signed_pre_key,
      registration_id: random_registration_id(),
      adv_secret_key: :crypto.strong_rand_bytes(32)
    }
  end

  defp random_registration_id do
    <<value::16>> = :crypto.strong_rand_bytes(2)
    Bitwise.band(value, 16_383)
  end
end
