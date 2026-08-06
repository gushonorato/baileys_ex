defmodule Baileys.DisconnectReason do
  @moduledoc false

  alias Baileys.Binary.Node
  alias Baileys.Disconnected

  @reason_codes %{
    connection_closed: 428,
    connection_lost: 408,
    connection_replaced: 440,
    timed_out: 408,
    logged_out: 401,
    bad_session: 500,
    restart_required: 515,
    multidevice_mismatch: 411,
    forbidden: 403,
    service_unavailable: 503
  }

  @code_reasons %{
    401 => :logged_out,
    403 => :forbidden,
    408 => :connection_lost,
    411 => :multidevice_mismatch,
    428 => :connection_closed,
    440 => :connection_replaced,
    500 => :bad_session,
    503 => :service_unavailable,
    515 => :restart_required
  }

  @known_reasons Map.keys(@reason_codes) ++ [:unknown]

  @hint_reasons %{
    "bad_session" => :bad_session,
    "conflict" => :connection_replaced,
    "connection_closed" => :connection_closed,
    "connection_lost" => :connection_lost,
    "connection_replaced" => :connection_replaced,
    "forbidden" => :forbidden,
    "logged_out" => :logged_out,
    "logout" => :logged_out,
    "multidevice_mismatch" => :multidevice_mismatch,
    "multi_device_mismatch" => :multidevice_mismatch,
    "replaced" => :connection_replaced,
    "restart_required" => :restart_required,
    "service_unavailable" => :service_unavailable,
    "timed_out" => :timed_out,
    "timeout" => :timed_out,
    "unauthorized" => :logged_out,
    "unavailable_service" => :service_unavailable
  }

  def from_stream(%Node{} = node) do
    hint = child_tag(node) || node.attrs["reason"]
    code = parse_code(node.attrs["code"]) || code_for_hint(hint) || 500
    disconnect(reason_for(code, hint, :bad_session), code)
  end

  def from_failure(%Node{} = node) do
    hint = node.attrs["reason"]
    code = parse_code(hint) || parse_code(node.attrs["code"]) || code_for_hint(hint) || 500
    disconnect(reason_for(code, hint, :bad_session), code)
  end

  def connection_closed, do: disconnect(:connection_closed, 428)
  def multidevice_mismatch, do: disconnect(:multidevice_mismatch, 411)
  def timed_out, do: disconnect(:timed_out, 408)

  def from_transport_error(reason) do
    case transport_status_code(reason) do
      nil ->
        if timeout?(reason),
          do: timed_out(),
          else: disconnect(:connection_lost, 408)

      code ->
        disconnect(reason_for(code, nil, :unknown), code)
    end
  end

  def from_exit({:shutdown, {:disconnected, reason, code}}, _status),
    do: disconnected(reason, code)

  def from_exit({:disconnected, reason, code}, _status), do: disconnected(reason, code)

  def from_exit(reason, :restarting) when reason in [:normal, :shutdown],
    do: disconnected(:restart_required, 515)

  def from_exit(:restart_required, _status), do: disconnected(:restart_required, 515)
  def from_exit(:qr_timeout, _status), do: disconnected(:timed_out, 408)
  def from_exit({:query_timeout, _id}, _status), do: disconnected(:timed_out, 408)
  def from_exit({:transport_error, reason}, status), do: from_transport_exit(reason, status)

  def from_exit(reason, _status) when reason in [:timeout, :timed_out, :etimedout],
    do: disconnected(:timed_out, 408)

  def from_exit(reason, _status)
      when reason in [:closed, :eclosed, :econnrefused, :econnreset, :enetdown, :enetunreach],
      do: disconnected(:connection_lost, 408)

  def from_exit(%{reason: reason}, status), do: from_exit(reason, status)
  def from_exit(_reason, _status), do: disconnected(:connection_closed, 428)

  def expected_exit?({:shutdown, {:disconnected, _reason, _code}}), do: true
  def expected_exit?(_reason), do: false

  def exit_reason({:disconnected, _reason, _code} = reason), do: {:shutdown, reason}

  defp from_transport_exit(reason, _status) do
    case from_transport_error(reason) do
      {:disconnected, disconnect_reason, code} -> disconnected(disconnect_reason, code)
    end
  end

  defp disconnect(reason, code), do: {:disconnected, reason, code}

  defp disconnected(reason, code) do
    %Disconnected{reason: normalize_reason(reason), code: normalize_code(code)}
  end

  defp reason_for(code, hint, fallback) do
    hint_reason = hint_reason(hint)

    cond do
      code == 408 and hint_reason == :timed_out -> :timed_out
      @reason_codes[hint_reason] == code -> hint_reason
      Map.has_key?(@code_reasons, code) -> @code_reasons[code]
      true -> if(is_nil(code), do: fallback, else: :unknown)
    end
  end

  defp code_for_hint(hint) do
    case hint_reason(hint) do
      nil -> nil
      reason -> @reason_codes[reason]
    end
  end

  defp hint_reason(hint) when is_atom(hint), do: hint |> Atom.to_string() |> hint_reason()

  defp hint_reason(hint) when is_binary(hint) do
    hint =
      hint
      |> String.trim()
      |> String.downcase()
      |> String.replace(~r/[\s-]+/, "_")

    @hint_reasons[hint]
  end

  defp hint_reason(_hint), do: nil

  defp child_tag(%Node{content: content}) when is_list(content) do
    case Enum.find(content, &match?(%Node{}, &1)) do
      %Node{tag: tag} -> tag
      nil -> nil
    end
  end

  defp child_tag(_node), do: nil

  defp parse_code(code) when is_integer(code), do: code

  defp parse_code(code) when is_binary(code) do
    case Integer.parse(code) do
      {parsed, ""} -> parsed
      _invalid -> nil
    end
  end

  defp parse_code(_code), do: nil

  defp normalize_reason(reason) when is_atom(reason) do
    if reason in @known_reasons, do: reason, else: :unknown
  end

  defp normalize_reason(_reason), do: :unknown
  defp normalize_code(code) when is_integer(code), do: code
  defp normalize_code(_code), do: nil

  defp timeout?(reason) when reason in [:timeout, :timed_out, :etimedout], do: true
  defp timeout?({:timeout, _detail}), do: true
  defp timeout?(%{reason: reason}), do: timeout?(reason)
  defp timeout?(_reason), do: false

  defp transport_status_code(%{status_code: code}) when is_integer(code), do: code
  defp transport_status_code(%{reason: reason}), do: transport_status_code(reason)
  defp transport_status_code({:unexpected_status, code}) when is_integer(code), do: code
  defp transport_status_code({:proxy, reason}), do: transport_status_code(reason)
  defp transport_status_code(_reason), do: nil
end
