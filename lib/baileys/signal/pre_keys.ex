defmodule Baileys.Signal.PreKeys do
  @moduledoc false

  alias Baileys.Binary.Node
  alias Baileys.Crypto

  @initial_count 812

  def initial_count, do: @initial_count

  def upload_node(credentials, count \\ @initial_count) do
    first = credentials.first_unuploaded_pre_key_id
    last = first + count - 1

    generated =
      Map.new(first..last, fn id ->
        {id, Map.get(credentials.pre_keys, id) || Crypto.generate_x25519_key_pair()}
      end)

    pre_keys = Map.merge(credentials.pre_keys, generated)

    credentials = %{
      credentials
      | pre_keys: pre_keys,
        next_pre_key_id: max(credentials.next_pre_key_id, last + 1)
    }

    node = %Node{
      tag: "iq",
      attrs: %{"xmlns" => "encrypt", "type" => "set", "to" => "s.whatsapp.net"},
      content: [
        %Node{tag: "registration", content: encode(credentials.registration_id, 4)},
        %Node{tag: "type", content: <<5>>},
        %Node{tag: "identity", content: credentials.signed_identity_key.public},
        %Node{
          tag: "list",
          content:
            Enum.map(first..last, fn id ->
              %Node{
                tag: "key",
                content: [
                  %Node{tag: "id", content: encode(id, 3)},
                  %Node{tag: "value", content: pre_keys[id].public}
                ]
              }
            end)
        },
        signed_pre_key_node(credentials.signed_pre_key)
      ]
    }

    {credentials, node, last}
  end

  def signed_pre_key_node(signed) do
    %Node{
      tag: "skey",
      content: [
        %Node{tag: "id", content: encode(signed.key_id, 3)},
        %Node{tag: "value", content: signed.key_pair.public},
        %Node{tag: "signature", content: signed.signature}
      ]
    }
  end

  defp encode(value, bytes), do: <<value::unsigned-big-integer-size(bytes)-unit(8)>>
end
