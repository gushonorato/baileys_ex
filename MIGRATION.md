# Event Parity Migration

## Session Schema

Session JSON is upgraded automatically and atomically:

| Version | Added state |
| --- | --- |
| 1 | Direct Signal sessions and credentials |
| 2 | Group sender-key records |
| 3 | Account settings, privacy tokens and pending server sync |
| 4 | History progress, pending history, app-state keys and LT-hash collections |

Legacy `session.etf` and nested `session.json` files are migrated on first load.
Keep a backup before upgrading and never run two clients against one session.

## Text Compatibility Window

An incoming supported text currently emits both:

1. `:messages_upsert`, the authoritative and complete event.
2. `:text_message`, a compatibility projection derived from that same upsert.

Applications subscribing to both must deduplicate by message key. New code
should perform business logic from `:messages_upsert` and use `:text_message`
only for legacy presentation paths.

```elixir
def handle_event(%Baileys.Event{type: :messages_upsert, data: upsert}, state) do
  Enum.each(upsert.messages, &store_complete_message/1)
  {:noreply, state}
end

def handle_event(%Baileys.Event{type: :text_message, data: text}, state) do
  render_legacy_text(text)
  {:noreply, state}
end
```

## Behavioral Changes

- Successful server message ACKs are silent; delivery comes from receipts.
- Historical messages are contained in `:messaging_history_set`, never replayed
  as online `:notify` upserts.
- Group notification system upserts are emitted before specialized group events.
- Credentials remain internal. Only non-secret account settings are public.
- Malformed recognized notifications are ACKed and ignored without terminating
  the connection.

## Rollback

Schema v4 readers accept versions 1-4, but older releases do not understand new
versions. Restore the pre-upgrade backup before running an older release; do not
manually remove keys from a live session document.
