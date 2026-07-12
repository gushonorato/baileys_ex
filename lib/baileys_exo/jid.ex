defmodule BaileysExo.JID do
  @moduledoc false

  @type t :: %__MODULE__{
          user: String.t(),
          server: String.t(),
          device: non_neg_integer() | nil,
          agent: non_neg_integer() | nil,
          domain_type: non_neg_integer()
        }

  @enforce_keys [:user, :server]
  defstruct [:user, :server, :device, :agent, domain_type: 0]

  def encode(user, server, device \\ nil, agent \\ nil) do
    user = to_string(user || "")
    agent = if agent in [nil, 0], do: "", else: "_#{agent}"
    device = if device in [nil, 0], do: "", else: ":#{device}"
    "#{user}#{agent}#{device}@#{server}"
  end

  def decode(jid) when is_binary(jid) do
    with [combined, server] <- String.split(jid, "@", parts: 2),
         [user_agent | device_parts] <- String.split(combined, ":", parts: 2),
         [user | agent_parts] <- String.split(user_agent, "_", parts: 2) do
      agent = parse_optional_integer(agent_parts)
      device = parse_optional_integer(device_parts)

      {:ok,
       %__MODULE__{
         user: user,
         server: server,
         device: device,
         agent: agent,
         domain_type: domain_type(server, agent)
       }}
    else
      _invalid -> {:error, :invalid_jid}
    end
  end

  def decode(_jid), do: {:error, :invalid_jid}

  def direct?(jid) when is_binary(jid) do
    String.ends_with?(jid, "@s.whatsapp.net") or String.ends_with?(jid, "@lid") or
      String.ends_with?(jid, "@hosted") or String.ends_with?(jid, "@hosted.lid")
  end

  def direct?(_jid), do: false

  defp domain_type("lid", _agent), do: 1
  defp domain_type("hosted", _agent), do: 128
  defp domain_type("hosted.lid", _agent), do: 129
  defp domain_type(_server, nil), do: 0
  defp domain_type(_server, agent), do: agent

  defp parse_optional_integer([]), do: nil

  defp parse_optional_integer([value]) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _invalid -> nil
    end
  end
end
