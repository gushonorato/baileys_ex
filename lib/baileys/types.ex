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

defmodule Baileys.Call do
  @moduledoc "Call lifecycle event. Events are emitted as ordered one-element batches."

  @type status ::
          :offer
          | :ringing
          | :preaccept
          | :transport
          | :relay_latency
          | :timeout
          | :reject
          | :accept
          | :terminate

  @type t :: %__MODULE__{
          id: String.t(),
          chat_id: String.t(),
          from: String.t() | nil,
          caller_pn: String.t() | nil,
          date: DateTime.t(),
          status: status(),
          offline?: boolean(),
          is_video?: boolean() | nil,
          is_group?: boolean() | nil,
          group_jid: String.t() | nil,
          latency_ms: number() | nil
        }

  @enforce_keys [:id, :chat_id, :date, :status]
  defstruct [
    :id,
    :chat_id,
    :from,
    :caller_pn,
    :date,
    :status,
    :is_video?,
    :is_group?,
    :group_jid,
    :latency_ms,
    offline?: false
  ]
end

defmodule Baileys.ContactUpdate do
  @moduledoc "Externally visible contact metadata change."
  @enforce_keys [:id, :img_url]
  defstruct [:id, :img_url]
end

defmodule Baileys.BlocklistUpdate do
  @moduledoc "Incremental blocklist change."
  @enforce_keys [:blocklist, :type]
  defstruct [:blocklist, :type]
end

defmodule Baileys.DefaultDisappearingMode do
  @moduledoc "Default disappearing-message account setting."
  @enforce_keys [:ephemeral_expiration, :ephemeral_setting_timestamp]
  defstruct [:ephemeral_expiration, :ephemeral_setting_timestamp]
end

defmodule Baileys.AccountSettings do
  @moduledoc "Non-secret account settings synchronized by WhatsApp."
  defstruct [:default_disappearing_mode]
end

defmodule Baileys.MediaRetryData do
  @moduledoc "Encrypted response to a media retry request."
  @enforce_keys [:ciphertext, :iv]
  defstruct [:ciphertext, :iv]
end

defmodule Baileys.MediaRetryError do
  @moduledoc "Media retry failure returned by WhatsApp."
  defstruct [:code, :status_code, attrs: %{}]
end

defmodule Baileys.MediaUpdate do
  @moduledoc "Media retry result targeting a complete message key."
  @enforce_keys [:key]
  defstruct [:key, :media, :error]
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
          raw_payloads: [binary()],
          timestamp: DateTime.t() | nil,
          status: atom() | nil,
          category: String.t() | nil,
          push_name: String.t() | nil,
          verified_business_name: String.t() | nil,
          stub_type: atom() | nil,
          stub_parameters: [term()],
          web_message_info: Baileys.Proto.WebMessageInfo.t() | nil,
          broadcast?: boolean(),
          offline?: boolean(),
          retry_count: non_neg_integer() | nil
        }

  @enforce_keys [:key]
  defstruct [
    :key,
    :content,
    :raw_content,
    :raw_payloads,
    :timestamp,
    :status,
    :category,
    :push_name,
    :verified_business_name,
    :stub_type,
    :stub_parameters,
    :web_message_info,
    :retry_count,
    broadcast?: false,
    offline?: false
  ]
end

defmodule Baileys.GroupParticipant do
  @moduledoc "Group participant with PN/LID alternatives and role."
  defstruct [:id, :phone_number, :lid, :username, :admin]
end

defmodule Baileys.GroupMetadata do
  @moduledoc "Complete metadata emitted when a group is created or discovered."

  @enforce_keys [:id]
  defstruct [
    :id,
    :subject,
    :addressing_mode,
    :owner,
    :owner_pn,
    :owner_username,
    :creation,
    :description,
    :description_id,
    :description_owner,
    :description_owner_pn,
    :description_owner_username,
    :description_time,
    :subject_owner,
    :subject_owner_pn,
    :subject_owner_username,
    :subject_time,
    :size,
    :linked_parent,
    :restrict?,
    :announce?,
    :member_add_mode?,
    :join_approval_mode?,
    :community?,
    :community_announce?,
    :ephemeral_duration,
    :invite_code,
    :author,
    :author_pn,
    :author_username,
    participants: []
  ]
end

defmodule Baileys.GroupUpdate do
  @moduledoc "Partial group metadata change."
  @enforce_keys [:id]
  defstruct [
    :id,
    :subject,
    :description,
    :announce?,
    :restrict?,
    :member_add_mode?,
    :ephemeral_duration,
    :invite_code,
    :join_approval_mode?,
    :author,
    :author_pn,
    :author_username
  ]
end

defmodule Baileys.GroupParticipantsUpdate do
  @moduledoc "Participant membership or role update."
  @enforce_keys [:id, :author, :participants, :action]
  defstruct [:id, :author, :author_pn, :author_username, :participants, :action]
end

defmodule Baileys.GroupJoinRequest do
  @moduledoc "Group membership approval request lifecycle update."
  @enforce_keys [:id, :author, :participant, :action]
  defstruct [
    :id,
    :author,
    :author_pn,
    :author_username,
    :participant,
    :participant_pn,
    :action,
    :method
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
  @moduledoc """
  Stable reason and status code for a closed connection.

  The library reports the transport or server reason without deciding whether
  the caller should retry, alert, or start a new pairing.
  """

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

defmodule Baileys.HistoryContact do
  @moduledoc "Contact projected from a history-sync payload."

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t() | nil,
          notify: String.t() | nil,
          verified_name: String.t() | nil,
          username: String.t() | nil,
          lid: String.t() | nil,
          phone_number: String.t() | nil
        }

  @enforce_keys [:id]
  defstruct [:id, :name, :notify, :verified_name, :username, :lid, :phone_number]
end

defmodule Baileys.LIDMapping do
  @moduledoc "A linked-identity mapping between a LID and phone-number JID."

  @type t :: %__MODULE__{lid: String.t(), pn: String.t()}
  @enforce_keys [:lid, :pn]
  defstruct [:lid, :pn]
end

defmodule Baileys.HistoryPastParticipant do
  @moduledoc "A former group participant included in history sync."

  @type t :: %__MODULE__{
          user_jid: String.t() | nil,
          leave_reason: atom() | nil,
          leave_timestamp: non_neg_integer() | nil
        }

  defstruct [:user_jid, :leave_reason, :leave_timestamp]
end

defmodule Baileys.HistoryPastParticipants do
  @moduledoc "Former participants grouped by chat."

  @type t :: %__MODULE__{
          group_jid: String.t() | nil,
          participants: [Baileys.HistoryPastParticipant.t()]
        }

  defstruct [:group_jid, participants: []]
end

defmodule Baileys.HistoryConversation do
  @moduledoc "Ordered conversation projected from a history-sync payload."

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t() | nil,
          display_name: String.t() | nil,
          username: String.t() | nil,
          lid: String.t() | nil,
          phone_number: String.t() | nil,
          new_jid: String.t() | nil,
          old_jid: String.t() | nil,
          last_message_timestamp: non_neg_integer() | nil,
          conversation_timestamp: non_neg_integer() | nil,
          unread_count: non_neg_integer() | nil,
          read_only?: boolean() | nil,
          archived?: boolean() | nil,
          marked_as_unread?: boolean() | nil,
          pinned: non_neg_integer() | nil,
          mute_end_time: non_neg_integer() | nil,
          end_of_history_transfer?: boolean() | nil,
          end_of_history_transfer_type: atom() | nil,
          ephemeral_expiration: non_neg_integer() | nil,
          ephemeral_setting_timestamp: integer() | nil,
          messages: [Baileys.Message.t()],
          web_conversation: Baileys.Proto.Conversation.t()
        }

  @enforce_keys [:id]
  defstruct [
    :id,
    :name,
    :display_name,
    :username,
    :lid,
    :phone_number,
    :new_jid,
    :old_jid,
    :last_message_timestamp,
    :conversation_timestamp,
    :unread_count,
    :read_only?,
    :archived?,
    :marked_as_unread?,
    :pinned,
    :mute_end_time,
    :end_of_history_transfer?,
    :end_of_history_transfer_type,
    :ephemeral_expiration,
    :ephemeral_setting_timestamp,
    :web_conversation,
    messages: []
  ]
end

defmodule Baileys.MessagingHistorySet do
  @moduledoc "A complete, ordered `messaging-history.set` payload."

  @type t :: %__MODULE__{
          conversations: [Baileys.HistoryConversation.t()],
          contacts: [Baileys.HistoryContact.t()],
          messages: [Baileys.Message.t()],
          status_v3_messages: [Baileys.Message.t()],
          lid_pn_mappings: [Baileys.LIDMapping.t()],
          past_participants: [Baileys.HistoryPastParticipants.t()],
          sync_type: atom() | nil,
          progress: non_neg_integer() | nil,
          chunk_order: non_neg_integer() | nil,
          latest?: boolean(),
          request_id: String.t() | nil,
          peer_data_request_session_id: String.t() | nil,
          original_message_id: String.t() | nil,
          oldest_message_in_chunk_timestamp: integer() | nil,
          enc_handle: String.t() | nil,
          complete_access_granted?: boolean() | nil
        }

  defstruct [
    :sync_type,
    :progress,
    :chunk_order,
    :request_id,
    :peer_data_request_session_id,
    :original_message_id,
    :oldest_message_in_chunk_timestamp,
    :enc_handle,
    :complete_access_granted?,
    conversations: [],
    contacts: [],
    messages: [],
    status_v3_messages: [],
    lid_pn_mappings: [],
    past_participants: [],
    latest?: false
  ]
end

defmodule Baileys.MessagingHistoryStatus do
  @moduledoc "History synchronization completion or inactivity state."
  @enforce_keys [:sync_type, :status, :explicit?]
  defstruct [:sync_type, :status, :explicit?]
end

defmodule Baileys.AppStateMutation do
  @moduledoc "Authenticated app-state mutation with its collection and version."
  @enforce_keys [:collection, :version, :operation, :index, :sync_action]
  defstruct [:collection, :version, :operation, :index, :sync_action]
end

defmodule Baileys.AppStateEffect do
  @moduledoc "Deterministic domain routing for an authenticated app-state mutation."
  @enforce_keys [:type, :data]
  defstruct [:type, :data]
end
