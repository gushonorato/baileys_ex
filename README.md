# Baileys

Minimal, OTP-native WhatsApp linked-device client.

The protocol implementation runs entirely on the BEAM. There is no Node.js,
JavaScript bridge, external process, Rustler or third-party native NIF. It uses
OTP `:crypto`/`:ssl` plus pure-Elixir libraries for WebSocket, protobuf and QR
rendering.

This project implements an unofficial WhatsApp Web protocol. It is not
affiliated with or endorsed by WhatsApp.

## Requirements

- Elixir 1.19 or later
- Erlang/OTP 28 or later

```sh
mix deps.get
```

## Callback Client

```elixir
defmodule MyWhatsApp do
  use Baileys

  def start_link(phone) do
    Baileys.start_link(__MODULE__, phone,
      name: __MODULE__,
      session: "primary",
      store: {Baileys.Store.File, root: Path.expand("baileys_sessions")}
    )
  end

  @impl Baileys
  def init(phone), do: {:ok, %{phone: phone}}

  @impl Baileys
  def handle_event(%Baileys.Event{type: :qr, data: qr}, state) do
    IO.inspect(qr.payload)
    {:noreply, state}
  end

  def handle_event(
        %Baileys.Event{client: client, type: :connection, data: %{state: :online}},
        state
      ) do
    Baileys.send_text(client, state.phone, "Hello World")
    {:noreply, state}
  end

  def handle_event(%Baileys.Event{type: :messages_upsert, data: upsert}, state) do
    Enum.each(upsert.messages, &IO.inspect(&1, label: "complete message"))
    {:noreply, state}
  end

  def handle_event(%Baileys.Event{type: :text_message, data: text}, state) do
    IO.puts("legacy text projection: #{text.text}")
    {:noreply, state}
  end

  def handle_event(_event, state), do: {:noreply, state}
end
```

`Baileys` is the behaviour and `Baileys.start_link/3` follows the same
`module, init_arg, options` shape as `GenServer.start_link/3`. The event's
`client` field can be used for synchronous commands inside the callback without
calling the callback process itself.

An explicit `store` is preferred; there is no implicit in-memory fallback. For
compatibility, `sessions_path: "/absolute/path"` remains shorthand for
`store: {Baileys.Store.File, root: "/absolute/path"}` when `store` is absent.
If both are supplied, `store` takes precedence. Credentials, prekeys, direct
Signal sessions and group sender-key records use a versioned JSON schema with
Base64 for binary fields. Schema v2 adds sender-key storage, schema v3 adds
non-secret account settings/privacy tokens, and schema v4 adds resumable
history/app-state data. Base64 is an encoding, not encryption; stored payloads
contain secrets and must not be shared or committed.

### Resetting an invalid session

`logout/1` asks WhatsApp to remove an authenticated linked device. When the
session has already been invalidated or removed on the phone, reset it locally
without reaching into store modules:

```elixir
:ok = Baileys.reset_session(client, reconnect: true)
```

The current connection is stopped, the configured store session is deleted,
fresh credentials are persisted, and the same client process reconnects and
starts emitting QR events. Reconnection defaults to `true`; use
`reconnect: false` to leave the client disconnected. A store failure is returned
as `{:error, {:store, reason}}`, and S3 conditional-write races are returned as
`{:error, {:store, :conflict}}`.

### Storage adapters

The filesystem adapter requires an absolute root and stores each session as
`<root>/<session>.json`:

```elixir
store: {Baileys.Store.File, root: "/var/lib/baileys"}
```

Schema v1-v3 JSON and files from the previous
`<root>/<session>/session.json` layout and legacy `session.etf` files are safely
migrated on first load. Directory and file modes are `0700` and `0600`, and
writes use a temporary file followed by an atomic rename.

The memory adapter must also be selected explicitly. Every client receives an
isolated store linked to its process, so all sessions in that instance disappear
when the client terminates:

```elixir
store: {Baileys.Store.Memory, []}
```

For S3, credentials come from the standard ExAws/AWS provider chain. Do not put
access keys in Baileys options:

```elixir
store: {
  Baileys.Store.S3,
  bucket: "my-baileys-sessions",
  region: "sa-east-1",
  prefix: "production/baileys"
}
```

`prefix` defaults to `"baileys"`, producing keys such as
`baileys/primary.json`. For S3-compatible services, pass ExAws overrides such as
`ex_aws_options: [scheme: "http://", host: "localhost", port: 9000]`. Requests
always use the official `ExAws.Request.Req` HTTP adapter.

S3 objects are atomically replaced by `PutObject`. The adapter remembers the
ETag returned by each load/save and requires it with `If-Match` for updates and
deletes. New sessions use `If-None-Match: *`. HTTP 409/412 is an explicit
`:conflict`; the adapter never retries as an unconditional overwrite. A missing
ETag is also an error. `Baileys.Store` supplies load/create, save and reset on
top of the adapter's fetch, put and idempotent delete operations.

To encrypt the JSON on the client before upload, configure an encryption
adapter. The built-in AES-256-GCM adapter accepts a Base64-encoded 32-byte key,
generates a new nonce for every write and authenticates the S3 object key:

```elixir
store: {
  Baileys.Store.S3,
  bucket: "my-baileys-sessions",
  region: "sa-east-1",
  prefix: "production/baileys",
  encryption: {
    Baileys.Store.S3.Encryption.AESGCM,
    key_base64: System.fetch_env!("BAILEYS_SESSION_KEY")
  }
}
```

Changing or losing this key makes existing sessions unreadable. Custom
client-side encryption can implement `Baileys.Store.S3.Encryption`.

The minimum IAM object permissions are `s3:GetObject`, `s3:PutObject` and
`s3:DeleteObject` for `<prefix>/*`. Grant `s3:ListBucket` on the bucket with an
`s3:prefix` condition restricted to that prefix. HTTP 404/`NoSuchKey` means a
new session; HTTP 403 remains an authorization error.

## QR Pairing

The executable example renders the QR directly in the terminal using a
pure-Elixir QR encoder.

### Full history synchronization

The default `:web` profile requests the normal browser history. To ask WhatsApp
for complete history while linking a new session, use the supported Windows
Desktop identity:

```elixir
Baileys.start_link(MyWhatsApp, init_arg,
  session: "full-history",
  store: {Baileys.Store.File, root: "/var/lib/baileys"},
  browser: :windows_desktop,
  sync_full_history: true
)
```

This sets `DeviceProps.requireFullSync` and advertises `WIN_HYBRID`. Baileys
never advertises the retired `WIN32` sub-platform. Configure these options
before the initial QR or pairing-code flow; changing them on an already linked
session does not cause WhatsApp to resend its initial history.

## Pairing Code

Request a code after connecting:

```elixir
{:ok, code} =
  Baileys.request_pairing_code(client, "+5511999999999")

IO.puts(code)
```

A custom eight-character alphanumeric code is optional:

```elixir
Baileys.request_pairing_code(
  client,
  "+5511999999999",
  custom_code: "ABCD1234"
)
```

## Send Text

```elixir
{:ok, %Baileys.SentMessage{} = sent} =
  Baileys.send_text(client, "+5511999999999", "Hello world")

IO.inspect(sent.id)
```

`send_text/4` resolves PN/LID devices with USync, obtains missing prekey
bundles, advances one Signal ratchet per device, synchronizes other linked
devices and relays the encrypted stanza. Delivery and read state arrive as
separate `:message_status` events.

`%Baileys.MessageStatus{}` has the following wire semantics:

| Incoming stanza | `status` | Public event |
| --- | --- | --- |
| Successful server `<ack class="message">` | none | no |
| Failed server `<ack class="message" error="...">` | `:failed` | yes |
| Receipt without `type` | `:delivered` | yes |
| Receipt `type="sender"` | `:sent` | yes |
| Receipt `type="read"` or `type="read-self"` | `:read` | yes |
| Receipt `type="played"` | `:played` | yes |
| Receipt `type="retry"` | none | no |
| Receipt `type="inactive"`, `hist_sync` or `peer_msg` | none | no |
| Unknown receipt type | none | no |

A successful server ACK only confirms stanza acceptance. It is not a delivery
confirmation and is intentionally silent. `:sent` comes from a sender receipt.
`MessageStatus.at` uses the receipt or failed-ACK Unix timestamp when valid and
falls back to local processing time only when that timestamp is absent or
invalid. Batched receipts produce one status event per message ID. For
`:failed`, `error` contains the server ACK attributes; it is `nil` for receipt
statuses.

Retry receipts are ACKed and never projected as delivery. The client keeps at
most 100 recent text payloads (and 1 MiB total) in connection memory, permits at
most five attempts per message/requesting device and limits requester
cardinality. Valid retries retain the logical message ID and re-encrypt for the
requesting device. Retry payloads and counters are not persisted, so pending
retry support is lost on disconnect or process restart. Missing material,
invalid bundles and exhausted limits are internal diagnostics, not delivery
events.

The complete example persists a `hello_world` session, waits for pairing and
sends `Hello world`:

```sh
mix run examples/hello_world.exs +5511999999999
```

## Interactive CLI

The interactive example sends and receives direct text messages without an
additional terminal UI dependency:

```sh
mix run examples/whatsapp_cli.exs
```

Use `/chat <phone>` to select the active conversation. The prompt always shows
the selected phone, and incoming messages include their source phone so that
messages from other conversations remain identifiable. Use `/help` to list the
available commands and `/quit` to exit.

The example uses `IO.gets/1`, which is sufficient for a small CLI. A full-screen
application that must preserve partially typed input while asynchronous
messages arrive should use a terminal UI/readline library.

## Event Types

```elixir
%Baileys.Event{client: client, type: :connection, data: %Baileys.Connection{}}
%Baileys.Event{client: client, type: :qr, data: %Baileys.QR{}}
%Baileys.Event{client: client, type: :paired, data: %Baileys.Account{}}
%Baileys.Event{client: client, type: :call, data: [%Baileys.Call{}]}
%Baileys.Event{client: client, type: :messages_upsert, data: %Baileys.MessagesUpsert{}}
%Baileys.Event{client: client, type: :messages_update, data: [%Baileys.MessageUpdate{}]}
%Baileys.Event{client: client, type: :messages_reaction, data: [%Baileys.MessageReaction{}]}
%Baileys.Event{client: client, type: :messages_media_update, data: [%Baileys.MediaUpdate{}]}
%Baileys.Event{client: client, type: :message_receipt_update, data: [%Baileys.MessageReceiptUpdate{}]}
%Baileys.Event{client: client, type: :contacts_update, data: [%Baileys.ContactUpdate{}]}
%Baileys.Event{client: client, type: :blocklist_update, data: %Baileys.BlocklistUpdate{}}
%Baileys.Event{client: client, type: :settings_update, data: %Baileys.AccountSettings{}}
%Baileys.Event{client: client, type: :messaging_history_set, data: %Baileys.MessagingHistorySet{}}
%Baileys.Event{client: client, type: :messaging_history_status, data: %Baileys.MessagingHistoryStatus{}}
%Baileys.Event{client: client, type: :app_state_mutations, data: [%Baileys.AppStateMutation{}]}
%Baileys.Event{client: client, type: :groups_upsert, data: [%Baileys.GroupMetadata{}]}
%Baileys.Event{client: client, type: :groups_update, data: [%Baileys.GroupUpdate{}]}
%Baileys.Event{client: client, type: :group_participants_update, data: %Baileys.GroupParticipantsUpdate{}}
%Baileys.Event{client: client, type: :group_join_request, data: %Baileys.GroupJoinRequest{}}
%Baileys.Event{client: client, type: :text_message, data: %Baileys.TextMessage{}}
%Baileys.Event{client: client, type: :message_status, data: %Baileys.MessageStatus{}}
%Baileys.Event{
  client: client,
  type: :disconnected,
  data: %Baileys.Disconnected{reason: reason, code: code}
}
%Baileys.Event{client: client, type: :error, data: %Baileys.Error{}}
```

Disconnect events preserve the server or transport reason and its status code.
Recoverable conditions such as `:connection_lost`, `:timed_out`,
`:service_unavailable`, and `:restart_required` remain distinct from conditions
that can require a new pairing, such as `:logged_out`, `:bad_session`, and
`:connection_replaced`. Retry and alert policy belongs to the application.

`:messages_upsert` is the authoritative complete-message event. It preserves the
decoded protobuf content, original wrappers, raw protobuf bytes, complete key
and stanza metadata. Online messages use `type: :notify`; offline messages use
`:append`. During the compatibility window, supported direct text emits both
`:messages_upsert` and the derived `:text_message` event. Media protobuf content
is observable, but media download and high-level media handling are not yet
provided.

Direct receipts produce `:messages_update` batches and continue producing the
legacy `:message_status` projection. Group and status receipts instead produce
per-user `:message_receipt_update` batches and are not collapsed into a direct
status. Reactions preserve both the target key and the complete author/event
message; an empty reaction text represents removal. Revoke and edit protocol
messages remain in the upsert stream and additionally produce targeted
`:messages_update` entries. Successful server ACKs remain silent, while failed
ACKs produce both the complete update and legacy failed status.

Unlike Baileys `7.0.0-rc13`, which stores group `played` receipts in its
`readTimestamp` field, this client uses the semantically correct
`played_timestamp` field.

Group messages encrypted with Signal sender keys enter the same authoritative
`:messages_upsert` stream. Sender-key distribution messages are processed before
group ciphertext when both occur in one stanza. Missing keys trigger at most
five retry receipts per message/sender and 100 total during one connection
lifecycle before further deliveries are only NACKed. Group creation,
participant changes, subject, description, settings, invite links and
membership approval operations also emit the typed events listed above after
their system-message upsert.

Call stanzas emit ordered one-element `:call` batches. Offer metadata is retained
for at most five minutes and 100 calls, then carried into ringing and terminal
events. Unknown or malformed call payloads are discarded but still ACKed.

Picture, account-sync blocklist/default-disappearing-mode and media-retry
notifications emit the typed events listed above. Device-list changes, peer
identity changes and low-prekey notifications are internal-only because they
maintain Signal state; low-prekey handling emits no public secret material.
Trusted-contact privacy tokens are persisted internally and attached to eligible
1:1 sends while current. Server-sync collection names are validated and persisted
for the history/app-state synchronization layer. Every recognized category is
ACKed exactly once, including malformed payloads.

History notifications remain visible in `:messages_upsert`, receive the required
`hist_sync` receipt, and are processed FIFO outside the socket process. Inline or
remote archives are hash/MAC checked, decrypted, inflated and emitted without
reordering as `:messaging_history_set`; historical messages retain their complete
`WebMessageInfo`. Progress, request/session IDs, LID mappings and pause/completion
status survive persistence and buffering boundaries.

App-state key shares and per-collection LT-hash state are persisted in schema v4.
Snapshots and consecutive patches validate value, index, snapshot, patch and
media MACs before versions advance. Verified actions are emitted as deterministic
typed `:app_state_mutations`; integrity failures leave prior state intact and
pending collections resume after reconnect.

## Lifecycle

```elixir
Baileys.status(client)
Baileys.disconnect(client)
Baileys.connect(client)
Baileys.logout(client)
```

`logout/1` requires an active authenticated connection. After the server
removes the linked device, the local session is reset.

## Native Protocol

The implementation includes:

- Mint WebSocket over OTP TLS.
- Noise XX with X25519, AES-256-GCM and SHA-256.
- WhatsApp BinaryNode codec and complete token dictionaries.
- Full generated WhatsApp message and protocol protobuf schema, pinned to a
  documented Baileys revision.
- XEd25519 signatures implemented in Elixir.
- Signal X3DH and Double Ratchet for direct messages.
- Signal sender-key distribution, chain ratchets and skipped-key handling for
  group messages.
- USync device/LID discovery and multi-device fanout.
- Atomic JSON session persistence with safe legacy ETF migration.

## Verification

```sh
mix format --check-formatted
mix compile --warnings-as-errors
mix test --warnings-as-errors
git diff --check
```
