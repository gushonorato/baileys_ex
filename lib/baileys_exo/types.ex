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

defmodule Baileys.MessageKey do
  @moduledoc "Complete WhatsApp message identity with PN/LID alternatives preserved."

  @type t :: %__MODULE__{
          remote_jid: String.t(),
          remote_jid_alt: String.t() | nil,
          remote_jid_username: String.t() | nil,
          from_me: boolean(),
          id: String.t(),
          participant: String.t() | nil,
          participant_alt: String.t() | nil,
          participant_username: String.t() | nil,
          addressing_mode: :pn | :lid,
          server_id: String.t() | nil,
          view_once?: boolean()
        }

  @enforce_keys [:remote_jid, :from_me, :id, :addressing_mode]
  defstruct [
    :remote_jid,
    :remote_jid_alt,
    :remote_jid_username,
    :id,
    :participant,
    :participant_alt,
    :participant_username,
    :addressing_mode,
    :server_id,
    from_me: false,
    view_once?: false
  ]
end

defmodule Baileys.Message do
  @moduledoc "Lossless decoded message envelope used by complete message events."

  @type t :: %__MODULE__{
          key: Baileys.MessageKey.t(),
          content: struct() | nil,
          raw_content: binary() | nil,
          timestamp: DateTime.t() | nil,
          status: atom() | nil,
          category: String.t() | nil,
          push_name: String.t() | nil,
          verified_business_name: String.t() | nil,
          broadcast?: boolean(),
          offline?: boolean(),
          retry_count: non_neg_integer() | nil
        }

  @enforce_keys [:key]
  defstruct [
    :key,
    :content,
    :raw_content,
    :timestamp,
    :status,
    :category,
    :push_name,
    :verified_business_name,
    :retry_count,
    broadcast?: false,
    offline?: false
  ]
end

defmodule Baileys.MessagesUpsert do
  @moduledoc "Batch of complete messages corresponding to Baileys `messages.upsert`."

  @type t :: %__MODULE__{
          messages: [Baileys.Message.t()],
          type: :append | :notify,
          request_id: String.t() | nil
        }

  @enforce_keys [:messages, :type]
  defstruct [:messages, :type, :request_id]
end

defmodule Baileys.MessageUpdate do
  @moduledoc "Update targeting a complete message key."

  @type t :: %__MODULE__{key: Baileys.MessageKey.t(), update: map()}
  @enforce_keys [:key, :update]
  defstruct [:key, :update]
end

defmodule Baileys.UserReceipt do
  @moduledoc "Per-user receipt timestamps for group or status messages."

  @type t :: %__MODULE__{
          user_jid: String.t() | nil,
          receipt_timestamp: DateTime.t() | nil,
          read_timestamp: DateTime.t() | nil,
          played_timestamp: DateTime.t() | nil,
          pending_device_jids: [String.t()],
          delivered_device_jids: [String.t()]
        }

  defstruct [
    :user_jid,
    :receipt_timestamp,
    :read_timestamp,
    :played_timestamp,
    pending_device_jids: [],
    delivered_device_jids: []
  ]
end

defmodule Baileys.MessageReceiptUpdate do
  @moduledoc "Per-user receipt update targeting a complete message key."

  @type t :: %__MODULE__{key: Baileys.MessageKey.t(), receipt: Baileys.UserReceipt.t()}
  @enforce_keys [:key, :receipt]
  defstruct [:key, :receipt]
end

defmodule Baileys.MessageReaction do
  @moduledoc "Reaction with separate target and author/event message keys."

  @type t :: %__MODULE__{target_key: Baileys.MessageKey.t(), reaction: Baileys.Message.t()}
  @enforce_keys [:target_key, :reaction]
  defstruct [:target_key, :reaction]
end

defmodule Baileys.SentMessage do
  @moduledoc "Text message accepted by the WhatsApp transport."

  @type t :: %__MODULE__{id: String.t(), to: String.t(), accepted_at: DateTime.t()}

  @enforce_keys [:id, :to, :accepted_at]
  defstruct [:id, :to, :accepted_at]
end

defmodule Baileys.MessageStatus do
  @moduledoc """
  Receipt-derived status for an outgoing message, or a failed server ACK.

  Successful server ACKs are silent. The timestamp comes from the stanza when
  valid and otherwise uses local processing time. Failed statuses retain the
  server ACK attributes in `error`.
  """

  @type status :: :failed | :sent | :delivered | :read | :played
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
