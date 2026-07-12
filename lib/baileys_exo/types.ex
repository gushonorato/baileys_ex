defmodule Baileys.Connection do
  @moduledoc "Connection state emitted by a client."

  @type state :: :disconnected | :connecting | :awaiting_pairing | :restarting | :online
  @type t :: %__MODULE__{state: state(), jid: String.t() | nil}

  @enforce_keys [:state]
  defstruct [:state, :jid]
end

defmodule Baileys.QR do
  @moduledoc "Raw QR payload to render and scan with the primary phone."

  @type t :: %__MODULE__{payload: String.t(), expires_at: DateTime.t() | nil}

  @enforce_keys [:payload]
  defstruct [:payload, :expires_at]
end

defmodule Baileys.Account do
  @moduledoc "Account linked to a client session."

  @type t :: %__MODULE__{jid: String.t() | nil, name: String.t() | nil}

  defstruct [:jid, :name]
end

defmodule Baileys.TextMessage do
  @moduledoc "Normalized incoming or synchronized text message."

  @type t :: %__MODULE__{
          id: String.t(),
          chat_jid: String.t(),
          sender_jid: String.t(),
          from_me: boolean(),
          text: String.t(),
          timestamp: DateTime.t(),
          offline?: boolean()
        }

  @enforce_keys [:id, :chat_jid, :sender_jid, :from_me, :text, :timestamp]
  defstruct [:id, :chat_jid, :sender_jid, :text, :timestamp, from_me: false, offline?: false]
end

defmodule Baileys.SentMessage do
  @moduledoc "Text message accepted by the WhatsApp transport."

  @type t :: %__MODULE__{id: String.t(), to: String.t(), accepted_at: DateTime.t()}

  @enforce_keys [:id, :to, :accepted_at]
  defstruct [:id, :to, :accepted_at]
end

defmodule Baileys.MessageStatus do
  @moduledoc "Delivery status update for an outgoing message."

  @type status :: :failed | :pending | :sent | :delivered | :read | :played | :unknown
  @type t :: %__MODULE__{
          id: String.t(),
          to: String.t(),
          status: status(),
          at: DateTime.t(),
          error: term() | nil
        }

  @enforce_keys [:id, :to, :status, :at]
  defstruct [:id, :to, :status, :at, :error]
end

defmodule Baileys.Disconnected do
  @moduledoc "Stable reason for a closed connection."

  @type reason ::
          :connection_closed
          | :connection_lost
          | :connection_replaced
          | :timed_out
          | :logged_out
          | :bad_session
          | :restart_required
          | :multidevice_mismatch
          | :forbidden
          | :service_unavailable
          | :unknown

  @type t :: %__MODULE__{reason: reason(), code: integer() | nil}

  @enforce_keys [:reason]
  defstruct [:reason, :code]
end

defmodule Baileys.Error do
  @moduledoc "Asynchronous transport or protocol error."

  @type t :: %__MODULE__{message: String.t(), code: integer() | nil}

  @enforce_keys [:message]
  defstruct [:message, :code]
end
