# Red/Green Regression Log

The implementation was developed phase-by-phase against synthetic fixtures.
Representative failing commands were recorded before each corresponding fix:

| Phase | Red command and failure | Green evidence |
| --- | --- | --- |
| 2.5 | `mix test test/connection_test.exs` failed missing sender-key retry registration and later a missing `session_path` key | Sender-key, combined `enc`, retry, migration and group regressions pass. |
| 2.6 | `mix test test/calls_test.exs` failed with undefined `Baileys.Calls`; `test/notification_test.exs` failed with undefined notification decoder | Typed call/notification and internal-state regressions pass. |
| 2.7 | History and app-state focused tests initially failed because the modules were absent; integration later failed JSON v4 and queue-state expectations | Integrity, FIFO, persistence, migration and resume regressions pass. |
| 2.8 | Property test initially referenced the wrong context protobuf type | Deterministic generated round trips and malformed-frame checks pass. |

Every phase was committed only after `mix format --check-formatted`, compilation
with warnings as errors, the full test suite and `git diff --check` passed.
