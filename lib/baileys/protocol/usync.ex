defmodule Baileys.Protocol.USync do
  @moduledoc false

  alias Baileys.Binary.{Node, NodeUtils}
  alias Baileys.JID

  def device_query(jids) do
    users =
      jids
      |> Enum.map(&normalize_user/1)
      |> Enum.uniq()
      |> Enum.map(fn jid -> %Node{tag: "user", attrs: %{"jid" => jid}, content: []} end)

    %Node{
      tag: "iq",
      attrs: %{"to" => "s.whatsapp.net", "type" => "get", "xmlns" => "usync"},
      content: [
        %Node{
          tag: "usync",
          attrs: %{
            "context" => "message",
            "mode" => "query",
            "sid" => Base.encode16(:crypto.strong_rand_bytes(8), case: :lower),
            "last" => "true",
            "index" => "0"
          },
          content: [
            %Node{
              tag: "query",
              content: [
                %Node{tag: "devices", attrs: %{"version" => "2"}},
                %Node{tag: "lid"}
              ]
            },
            %Node{tag: "list", content: users}
          ]
        }
      ]
    }
  end

  def parse_devices(reply, my_jid, my_lid \\ nil) do
    with %Node{} = usync <- NodeUtils.child(reply, "usync"),
         %Node{} = list <- NodeUtils.child(usync, "list") do
      entries =
        list.content
        |> List.wrap()
        |> Enum.filter(&match?(%Node{tag: "user"}, &1))
        |> Enum.map(&parse_user/1)

      mappings =
        for %{jid: pn, lid: lid} <- entries, is_binary(lid), into: %{}, do: {pn, lid}

      devices = extract_devices(entries, my_jid, my_lid)
      {:ok, devices, mappings}
    else
      _missing -> {:error, :invalid_usync_response}
    end
  end

  def bundle_query(jids) do
    users = Enum.map(jids, &%Node{tag: "user", attrs: %{"jid" => &1}})

    %Node{
      tag: "iq",
      attrs: %{"xmlns" => "encrypt", "type" => "get", "to" => "s.whatsapp.net"},
      content: [%Node{tag: "key", content: users}]
    }
  end

  def parse_bundles(reply) do
    with %Node{} = list <- NodeUtils.child(reply, "list") do
      list.content
      |> List.wrap()
      |> Enum.filter(&match?(%Node{tag: "user"}, &1))
      |> Enum.reject(&(not is_nil(NodeUtils.child(&1, "error"))))
      |> Map.new(fn user -> {user.attrs["jid"], parse_bundle(user)} end)
      |> then(&{:ok, &1})
    else
      _missing -> {:error, :invalid_bundle_response}
    end
  end

  def parse_retry_bundle(%Node{} = receipt) do
    case NodeUtils.child(receipt, "keys") do
      nil ->
        :none

      %Node{} = keys ->
        with <<5>> <- child_content(keys, "type"),
             <<identity::binary-size(32)>> <- child_content(keys, "identity"),
             registration when is_integer(registration) <-
               decode_bounded_integer(child_content(receipt, "registration"), 4),
             %Node{} = signed <- NodeUtils.child(keys, "skey"),
             {:ok, signed_pre_key} <- parse_retry_key(signed, true),
             {:ok, pre_key} <- parse_optional_retry_key(NodeUtils.child(keys, "key")) do
          bundle = %{
            registration_id: registration,
            identity_key: wire_key(identity),
            signed_pre_key: signed_pre_key
          }

          {:ok, if(pre_key, do: Map.put(bundle, :pre_key, pre_key), else: bundle)}
        else
          _invalid -> {:error, :invalid_retry_bundle}
        end
    end
  end

  def parse_retry_bundle(_receipt), do: {:error, :invalid_retry_bundle}

  def parse_retry_registration(%Node{} = receipt) do
    case NodeUtils.child(receipt, "registration") do
      nil ->
        {:ok, nil}

      %Node{content: content} ->
        case decode_bounded_integer(content, 4) do
          registration when is_integer(registration) -> {:ok, registration}
          nil -> {:error, :invalid_retry_registration}
        end
    end
  end

  def parse_retry_registration(_receipt), do: {:error, :invalid_retry_registration}

  defp parse_user(%Node{} = user) do
    devices_node = NodeUtils.child(user, "devices")
    device_list = devices_node && NodeUtils.child(devices_node, "device-list")

    devices =
      case device_list do
        %Node{content: children} when is_list(children) ->
          children
          |> Enum.filter(&match?(%Node{tag: "device"}, &1))
          |> Enum.map(fn device ->
            %{
              id: integer_attr(device, "id", 0),
              key_index: integer_attr(device, "key-index", nil)
            }
          end)

        _missing ->
          []
      end

    lid_node = NodeUtils.child(user, "lid")
    %{jid: user.attrs["jid"], lid: lid_node && lid_node.attrs["val"], devices: devices}
  end

  defp extract_devices(entries, my_jid, my_lid) do
    {:ok, me} = JID.decode(my_jid)
    my_lid_user = if my_lid, do: elem(JID.decode(my_lid), 1).user

    Enum.flat_map(entries, fn entry ->
      case JID.decode(entry.jid) do
        {:ok, decoded} ->
          Enum.flat_map(entry.devices, fn device ->
            own? = decoded.user in [me.user, my_lid_user] and device.id == (me.device || 0)
            addressable? = device.id == 0 or not is_nil(device.key_index)

            if not own? and addressable? do
              [
                %{
                  user: decoded.user,
                  device: device.id,
                  server: decoded.server,
                  jid: JID.encode(decoded.user, decoded.server, device.id)
                }
              ]
            else
              []
            end
          end)

        {:error, :invalid_jid} ->
          []
      end
    end)
  end

  defp parse_bundle(user) do
    signed = NodeUtils.child(user, "skey")
    pre_key = NodeUtils.child(user, "key")

    bundle = %{
      registration_id: decode_integer(child_content(user, "registration")),
      identity_key: wire_key(child_content(user, "identity")),
      signed_pre_key: parse_key(signed, true)
    }

    if pre_key, do: Map.put(bundle, :pre_key, parse_key(pre_key, false)), else: bundle
  end

  defp parse_key(node, signed?) do
    key = %{
      key_id: decode_integer(child_content(node, "id")),
      public: wire_key(child_content(node, "value"))
    }

    if signed?, do: Map.put(key, :signature, child_content(node, "signature")), else: key
  end

  defp parse_retry_key(node, signed?) do
    with key_id when is_integer(key_id) <- decode_bounded_integer(child_content(node, "id"), 3),
         <<public::binary-size(32)>> <- child_content(node, "value"),
         signature when not signed? or is_binary(signature) <- child_content(node, "signature") do
      key = %{key_id: key_id, public: wire_key(public)}
      {:ok, if(signed?, do: Map.put(key, :signature, signature), else: key)}
    else
      _invalid -> {:error, :invalid_retry_bundle}
    end
  end

  defp parse_optional_retry_key(nil), do: {:ok, nil}
  defp parse_optional_retry_key(node), do: parse_retry_key(node, false)

  defp child_content(node, tag) do
    case NodeUtils.child(node, tag) do
      %Node{content: content} when is_binary(content) -> content
      _missing -> nil
    end
  end

  defp wire_key(<<5, _::binary-size(32)>> = key), do: key
  defp wire_key(<<key::binary-size(32)>>), do: <<5, key::binary>>
  defp wire_key(nil), do: nil

  defp decode_integer(nil), do: nil
  defp decode_integer(binary), do: :binary.decode_unsigned(binary, :big)

  defp decode_bounded_integer(binary, max_bytes)
       when is_binary(binary) and byte_size(binary) >= 1 and byte_size(binary) <= max_bytes do
    :binary.decode_unsigned(binary, :big)
  end

  defp decode_bounded_integer(_binary, _max_bytes), do: nil

  defp integer_attr(node, key, default) do
    case Integer.parse(node.attrs[key] || "") do
      {integer, ""} -> integer
      _invalid -> default
    end
  end

  defp normalize_user(jid) do
    case JID.decode(jid) do
      {:ok, decoded} -> JID.encode(decoded.user, decoded.server)
      {:error, :invalid_jid} -> jid
    end
  end
end
