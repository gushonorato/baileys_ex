# Event Parity Matrix

Reference: Baileys `7.0.0-rc13`, commit
`731cd6b5d1991a16d0c65072fd3107c43968e4a9`.

| Reference event or subsystem | Status | Elixir contract | Notes |
| --- | --- | --- | --- |
| `connection.update` | partial | `:connection`, `:qr`, `:paired`, `:disconnected`, `:error` | Lifecycle is stable; reference telemetry fields are not mirrored. |
| `creds.update` | internal-only | Versioned session JSON | Secret credentials are never published. Non-secret settings have `:settings_update`. |
| `messages.upsert` | partial | `:messages_upsert` | Preserves content, wrappers, all decrypted payload bytes and complete keys. Request IDs are preserved when present; PDO placeholder resend is not implemented. |
| Direct text compatibility | complete | `:text_message` | Derived from the authoritative upsert; no second decode path. |
| `messages.update` | complete | `:messages_update` | Includes direct receipts, failed ACKs, revoke and edit projections. |
| `messages.reaction` | complete | `:messages_reaction` | Target and actor/event keys remain separate. |
| `message-receipt.update` | complete | `:message_receipt_update` | Per-user group/status timestamps preserve played separately from read. |
| `messages.media-update` | complete | `:messages_media_update` | Exposes encrypted retry response or typed error. |
| Group messages | complete | `:messages_upsert` | Signal sender-key state is authenticated, ratcheted and persisted. |
| Group metadata and participants | partial | `:groups_upsert`, `:groups_update`, `:group_participants_update`, `:group_join_request` | Core lifecycle is typed; extended community/ownership metadata remains partial. |
| `call` | partial | `:call` | Lifecycle and offer metadata are complete; reference-derived missed-call system upserts are not synthesized. |
| `contacts.update` picture changes | complete | `:contacts_update` | Group pictures also produce a system-message upsert. |
| `blocklist.update` | complete | `:blocklist_update` | Account-sync deltas are emitted individually. |
| Device and identity notifications | internal-only | Signal session maintenance | PN/LID aliases are invalidated together. |
| Low-prekey notifications | internal-only | Deferred ACK and bounded upload retries | Pending uploads resume after reconnect. |
| Trusted-contact tokens | internal-only | Versioned token store | Current tokens are attached to eligible direct sends. |
| `messaging-history.set` | complete | `:messaging_history_set` | Ordered chunks preserve request/session IDs, mappings, past participants and complete historical `WebMessageInfo`. |
| History status | complete | `:messaging_history_status` | Explicit completion and inactivity pause are distinct. |
| App-state patches | partial | `:app_state_mutations`, `:app_state_effects` | Integrity, versions and deterministic domain routing are complete; high-level action-specific convenience structs remain generic. |
| `messages.delete` | partial | `:app_state_effects` | Authenticated delete actions are routed generically. |
| `chats.*` | partial | `:app_state_effects` | Authenticated chat mutations are routed generically. |
| `contacts.upsert` | partial | `:app_state_effects` | App-state contact actions are generic; picture updates are typed separately. |
| `blocklist.set` | out of scope | none | Incremental `blocklist.update` is supported; initial fetch is not exposed. |
| Labels, member tags and message capping | out of scope | none | No stable high-level Elixir contract yet. |
| Newsletters | partial | `:messages_upsert` | Complete message envelopes exist; newsletter-specific management events are not exposed. |
| Presence and chat-state events | out of scope | none | Not required by the current event-parity plan. |

## Intentional Differences

- Group `played` receipts populate `played_timestamp`. The pinned reference
  incorrectly writes them to `readTimestamp`.
- Unknown call children are ignored rather than incorrectly projected as
  `ringing`.
- App-state record, aggregate and media integrity checks are mandatory. The
  pinned reference can run with checks disabled.
- App-state versions use full unsigned 64-bit encoding rather than the
  reference's JavaScript low-word quirk.
- History and app-state buffering retain request IDs and LID/PN mappings.
