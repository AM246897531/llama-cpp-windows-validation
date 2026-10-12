# Bounded resident-server Windows performance protocol

`windows-model-calibration.ps1` keeps its short authenticated JSON calibration
as the default. `-WarmBenchmark` adds selected performance probes after the same
pinned downloads, native Job, ACL, loopback authentication and PDH checks. It
does not adopt a production setting or turn cloud results into consumer-target
evidence. Run only on real x64 Windows with PowerShell 7.3+.

```powershell
& ./scripts/bench/windows-model-calibration.ps1 `
  -WarmBenchmark -ProbeSet @('pp500') -BallastGiB 0 `
  -WarmupRuns 3 -Repetitions 30 -Threads 4 `
  -BenchmarkTimeoutSeconds 6900 `
  -ResultDirectory work/bench/windows-t4-pp500-ballast0
```

Use separate jobs/result directories for `pp500`, `pp1500`, `pp3000`, `tg128`,
`full-context` and `thermal`, and for requested ballast 0/2/4 GiB. A job timeout
of 120 minutes leaves a small margin beyond the maximum 115-minute owned-model
duration for downloads and reporting; shorten the owned timeout when download
time needs a larger margin. A case that exceeds its timeout fails with raw
completed records retained. The harness never reduces sample counts, model,
context or memory floor to make the matrix fit. `-ProbeOnly` and
`-WarmBenchmark` are mutually exclusive.

Every admitted pp/tg/full-context case has at least three warmups followed by
at least 30 measured requests against one resident server. `/tokenize` produces
numeric token IDs from a fixed synthetic English fixture; numeric prompts avoid
automatic BOS insertion at the completion endpoint. Input lengths are exact:

| Case | Prompt tokens | Generated tokens | Measurement |
| --- | ---: | ---: | --- |
| pp500 | 500 | 1 | Native prompt-processing rate |
| pp1500 | 1500 | 1 | Native prompt-processing rate |
| pp3000 | 3000 | 1 | Native prompt-processing rate |
| tg128 | 500 | 128 | Native generation rate after a 500-token prompt |
| full-context | 3968 | 128 | Request reaches the 4096-token context budget |

Requests explicitly disable prompt reuse, ignore EOS and use deterministic
sampling. Native `prompt_n`, `predicted_n`, `cache_n`, truncation and positive
prompt timings are validated before accepting a repetition. Positive generation
timings are also required for the 128-token probes; a one-token pp request does
not produce a generation-throughput claim. Native timing records,
wall-clock request times and memory-sample ranges are appended to
`benchmark.jsonl`; generated prose is not retained or treated as quality
evidence. The summary contains means, medians, p95, extrema and sample standard
deviations. Prompt token-ID digests identify the exact synthetic inputs.

The thermal case has three short warmups and **one** continuous five-minute
decode window, beginning at the first token arrival. It records raw token-ID
arrival counts and compares the complete first and last 60-second windows.
After 300 seconds the client cancels its request; owned-process cleanup remains
under the same Job. This is client arrival throughput with 250ms watchdog
polling, not a temperature sensor or proof that a speed change was caused by
heat. Context shifting remains disabled. If the fixed 4096-token capacity is
exhausted before five minutes, the case fails and makes no sustained-window
claim; the harness does not silently grow context or enable shifting. Thermal
is not represented as 30 independent five-minute samples.

The unchanged experiment envelope reserves all pinned model bytes plus a
2 GiB **private committed memory cap** for the owned server and a 3 GiB free-memory
floor. File-backed model residency is not covered by the Job private-commit
cap, so it is reserved separately and monitored through actual Windows working
set/private working set and PDH gauges. Native launch stays suspended until
assignment to the one-process, kill-on-close Job. Repacking is disabled solely
as a diagnostic candidate; model SHA, context4096, np1, F16 K/V, CPU-only,
mmap, batch512/ubatch128, cache0 and checkpoint0 remain explicit. A 512 MiB
buffer triggers early cancellation before the memory floor; there is no hard
guarantee against unrelated OS allocations between samples.

Ballast is owned `VirtualAlloc` memory, admitted before allocation with the
entire model budget still reserved. It is committed in 64 MiB chunks, touched
on every 4 KiB page, checked with real PDH gauges between chunks and released
in `finally`. Capacity is rechecked before the model launches. Unsafe 2/4 GiB
cases report `NOT_ADMITTED`; they are not forced onto 16 GiB hardware by
shrinking product parameters. Ballast belongs to the harness, outside the
native child's private-commit cap.

`run-manifest.json` retains script/config/model/native/archive/source hashes,
actual hardware, Defender, active power plan, admission and cleanup observations,
case counts and memory peaks. Public CI may retain only the manifest,
`memory.jsonl`, `benchmark.jsonl`, and native logs after the existing explicit
secret inspection/redaction gate. The ephemeral key file is never an artifact.
Add `benchmark.jsonl` to the public workflow metadata artifact allowlist when
running this mode. Each job remains a partial matrix result until successful
reports from all required selections are joined by their exact configuration
and source identities.

All runs remain **warm-only**: no reboot or verified standby purge is performed.
Defender and power plans are observed without changing them. Defender off or
unknown invalidates the required real-time-protected baseline conditions even
when performance samples complete. Memory channels, CPU efficiency topology,
GPU details, Balanced/Best-performance and AC/battery matrices, isolated cold
load, FastPath latency, application quality, flag ablations and representative
16 GiB consumer-machine validation remain unresolved. The script continues to
report `full_I3: NOT VALIDATED` and `production_adoption: false`.

This generic SILVER protocol never contains private application sources,
documents, owner acceptance notes, user data or model weights. It neither
requests paid hardware nor grants publication or product cutover permission.
