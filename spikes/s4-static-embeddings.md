# S4 static embedding reality spike

This development-only harness measures `minishlab/potion-multilingual-128M`
(Model2Vec), pinned to `73908c3438cf03b6a01bcb9611d62b23d0726f08`, under MIT.
It does not integrate a provider, choose a production winner, or measure a
transformer reranker. Product dependencies, model/context defaults and UI stay
outside this spike.

Preparation uses only pinned public Hugging Face assets and published PyPI wheel
hashes. The official ONNX is 512,365,657 bytes, SHA256
`83eb52eb180d773fe409799701452896170e3b605756a6806335c5e354092e34`;
its tokenizer is 18,616,131 bytes, SHA256
`19f1909063da3cfe3bd83a782381f040dccea475f4816de11116444a73e1b6a1`.
Three small configuration files are also checked against fixed hashes. No
pickle, `trust_remote_code`, model safetensors download or runtime hub lookup is
used. Model/tokenizer downloads total about 531 MB; derived artifacts and the
isolated toolchain remain in ignored `work/`.

For actual Windows cloud preparation with a known Python 3.12 executable:

```powershell
$env:PYTHONDONTWRITEBYTECODE = '1'
python spikes/s4-static-embeddings.py prepare `
  --assets work/models/potion-multilingual-128M `
  --wheelhouse work/toolchains/s4-static-wheelhouse --wheel-platform windows
python -m venv work/toolchains/s4-static-onnx
& work/toolchains/s4-static-onnx/Scripts/python.exe -m pip install `
  --no-index --find-links work/toolchains/s4-static-wheelhouse --require-hashes `
  -r spikes/s4-static-embeddings-requirements-windows.txt
& work/toolchains/s4-static-onnx/Scripts/python.exe -m pip check
$python = (Resolve-Path work/toolchains/s4-static-onnx/Scripts/python.exe).Path
./spikes/s4-static-windows.ps1 -PythonExecutable $python `
  -Threads 4 -ResultDirectory work/phase1-results/s4-static-windows
```

Select the executable explicitly from the cloud runner's Python 3.12 toolcache
when `python` resolves to a different version. Windows commands run synchronously;
check `$LASTEXITCODE` after each. The thread count is an explicit experimental
profile; choose 2 for a two-CPU runner or 4 for a four-CPU runner. It does not
reduce the product target or model quality. The controlled wrapper requires
9 GiB of actual available RAM: a 6 GiB aggregate private-commit Job budget plus
a 3 GiB reserve. Its separate 4 GiB per-process limit has more than 1 GiB of
headroom above the observed Linux preparation OS peak of 3,177,345,024 bytes.
It rejects an 8 GB runner safely before launch; rejection is compatibility
evidence, never representative consumer performance. This is a conservative
experimental envelope, not measured Windows production admission overhead.
The parent and each sequential flavor worker stay in the same owned Job;
four process slots account for Windows virtual-environment redirectors.
Assignment occurs before the launcher resumes. PDH watches actual available RAM
and paging every 250 ms, cancels before the 3 GiB floor, and writes raw samples.
Kill-on-close stops owned processes on error/timeout, with a 600 second default.
The child receives an explicit Unicode allowlist of necessary system/Python
settings. Temporary paths, user profile, application-data and hub-cache paths
point into this experiment's owned directory; CI credentials, proxies and
unrelated inherited variables are excluded. UTF8 and user-site isolation are
explicit, and virtual-environment redirectors retain the system loader paths.

Linux setup follows the same commands with `bin/python`,
`--wheel-platform linux` and the Linux requirements file. Actual measured
inference and native network tracing are separate from online preparation:

```bash
PYTHONDONTWRITEBYTECODE=1 strace -f -qq -e trace=network \
  -o work/spikes/s4-static-network.log \
  work/toolchains/s4-static-onnx/bin/python spikes/s4-static-embeddings.py \
  benchmark --threads 4 --results work/phase1-results/s4-static-linux
```

Both evidence directory and derived `s4-derived-gather-uint8.onnx` must be new.
The harness refuses overwrites. Preserve earlier evidence/artifacts, or select
a fresh owned asset directory; never remove unknown profiles or source files.
`prepare` is the sole network-enabled mode. `benchmark` verifies assets, sets
HF/Transformers offline and telemetry flags, exercises a Python network audit
guard before DNS, and uses local tokenizer/ONNX paths. Every flavor runs in a
separate owned worker process, releasing its model before the next flavor.
The Python guard proves Python call blocking; Linux `strace` is the separate
native network syscall evidence. Windows native network verification remains
a separate real Windows test requirement; the wrapper truthfully marks it
unmeasured. Local-only paths and Python guard results do not prove every native
C++ socket call is absent.

The pinned ONNX graph uses **flattened int64 `input_ids` and int64 start
`offsets`**, not `attention_mask`. It averages a `[500353,256]` token table inside
an EmbeddingBag Loop, then applies L2 normalization. Disable special tokens,
remove Unigram unknown ID 1, and reject empty or out-of-table inputs before
inference. Added BOS/EOS IDs exceed the embedding table; silently including them
would be invalid. No token truncation or padding is applied. The float output is
checked against an independent NumPy mean/L2 reference from the official table.

ORT 1.23.1 dynamic Gather quantization requires `EnableSubgraph=True`, because
the embedding-weight Gather is inside the Loop. Its Gather handler uses the
activation quantizer, producing **UINT8**, even when `weight_type=QInt8` is
requested. The final harness explicitly requests QUInt8 and verifies the actual
UINT8 table. This is an eight-bit candidate, not a claim of signed INT8 weights.
The derived weight format, graph, size and hash are recorded.

Thirty synthetic Hebrew/English/Aramaic query/window pairs produce 60 embeddings.
Original generated strings and exact token IDs are frozen in `inputs.json` with
hashes. Each flavor measures tokenization, single-query inference and complete
30-pair inference at batches 1/8, with three warmups and 30 timed repetitions.
Load time, full raw timings/distributions, memory samples, exact thread/provider
settings, dependency versions and source/config/input hashes are retained.
Filesystem cache is uncontrolled; these are warm component timings. Preparation
and fresh worker/session loads are reported separately.

Cosine changes, absolute vector changes and synthetic rank agreement measure
numerical quantization behavior. They establish no human GOLD quality, domain
recall, verified citations, meaning-window acceptance or product acceptance. Frozen evaluation TEST and
personal/project source contents are never read. Actual Windows results are
required before any Windows claim; consumer-target validation remains separate.

The dedicated standard `windows-latest` workflow is maintained at
`scripts/bench/public-static-embeddings-windows.yml` for review before copying
it to a generic public validation fork. It installs only the hash-required
isolated wheel set with pip's `--no-index`, confirms Defender ON, and invokes
the wrapper at four explicit threads. Metadata upload uses six exact files;
weights, toolchains and unreviewed diagnostics are excluded. Compressed log
markers retain original raw timing/memory bytes with SHA256 digests so evidence
can be recovered even when a developer proxy blocks a dynamic artifact host.
The local `scripts/bench/recover-static-windows.cjs` decoder requires all six
complete files, verifies original/compressed SHA256 and bytes, then validates
actual Windows/pins/Defender/admission/cleanup/three-warmup/thirty-sample metadata.
Public copies may include only this standalone synthetic harness, its pinned
dependency files, this guide, the generic supervisor and the dedicated workflow.
No private application, specification, owner review, user source or model weight
belongs in that fork.
