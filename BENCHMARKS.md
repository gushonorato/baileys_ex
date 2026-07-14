# Envelope Benchmark Notes

Run `BENCH_ITERATIONS=1000 mix run scripts/benchmark_envelopes.exs` to compare
protobuf processing and retained BEAM words for synthetic complete message and
history envelopes at 1 KiB, 64 KiB and 1 MiB.

The current decision is to retain raw payload bytes inline because they are part
of the lossless event contract and typical messages are small. The history FIFO,
64 MiB encrypted-download limit and 128 MiB inflated-history limit bound transient
pressure. Revisit a reference/store abstraction if production measurements show
large retained histories or subscriber backpressure; the public `raw_payloads`
field makes that future migration explicit rather than silently dropping bytes.
