#!/usr/bin/env python3
"""Bounded, offline Model2Vec reality spike; no production model adoption."""
from __future__ import annotations

import argparse
import collections
import ctypes
import datetime as dt
import gc
import hashlib
import importlib.metadata
import json
import math
import os
from pathlib import Path
import platform
import socket
import statistics
import subprocess
import sys
import threading
import time
import urllib.request

sys.dont_write_bytecode = True
os.environ["PYTHONDONTWRITEBYTECODE"] = "1"

PROJECT = Path(__file__).resolve().parents[1]
REPOSITORY = "minishlab/potion-multilingual-128M"
REVISION = "73908c3438cf03b6a01bcb9611d62b23d0726f08"
ASSETS = [
    {"path": "onnx/model.onnx", "bytes": 512365657, "sha256": "83eb52eb180d773fe409799701452896170e3b605756a6806335c5e354092e34"},
    {"path": "tokenizer.json", "bytes": 18616131, "sha256": "19f1909063da3cfe3bd83a782381f040dccea475f4816de11116444a73e1b6a1"},
    {"path": "config.json", "bytes": 271, "sha256": "595e4cab2093732efd5dbe084fd5c1826b5eea693b73b4c1fd971672867d2e54"},
    {"path": "tokenizer_config.json", "bytes": 1898, "sha256": "bd0e8c3a56aeac5078a6445e6b04425cd17b41bcc8d382ae925b5dbca287f8eb"},
    {"path": "special_tokens_map.json", "bytes": 167, "sha256": "d05497f1da52c5e09554c0cd874037a083e1dc1b9cfd48034d1c717f1afc07a7"},
]
OFFLINE_EVENTS: list[str] = []


def digest(path: Path) -> str:
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def json_bytes(value) -> bytes:
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode()


def write_json(path: Path, value) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("x", encoding="utf8") as stream:
        json.dump(value, stream, ensure_ascii=False, indent=2)
        stream.write("\n")


def owned_work_path(value: str) -> Path:
    path = Path(value).resolve()
    if not path.is_relative_to(PROJECT / "work"):
        raise ValueError("Assets/toolchains must remain in project work/")
    return path


def verify_assets(directory: Path) -> list[dict]:
    for asset in ASSETS:
        path = directory / asset["path"]
        if not path.is_file() or path.stat().st_size != asset["bytes"] or digest(path) != asset["sha256"]:
            raise ValueError(f"Pinned asset integrity failure: {asset['path']}")
    return ASSETS


def fetch(url: str, target: Path, expected: dict) -> None:
    if target.exists():
        if target.stat().st_size != expected["bytes"] or digest(target) != expected["sha256"]:
            raise ValueError(f"Existing artifact failed integrity: {target.name}")
        return
    target.parent.mkdir(parents=True, exist_ok=True)
    partial = target.with_name(target.name + ".s4-part")
    if partial.exists():
        raise ValueError(f"Owned preparation partial already exists: {partial.name}")
    count = 0
    checksum = hashlib.sha256()
    try:
        with urllib.request.urlopen(url, timeout=90) as response, partial.open("xb") as output:
            while block := response.read(4 * 1024 * 1024):
                count += len(block)
                if count > expected["bytes"]:
                    raise ValueError("Artifact exceeds pinned byte size")
                checksum.update(block)
                output.write(block)
        if count != expected["bytes"] or checksum.hexdigest() != expected["sha256"]:
            raise ValueError(f"Downloaded artifact integrity failure: {target.name}")
        partial.rename(target)
    finally:
        if partial.exists():
            partial.unlink()


def prepare(args) -> None:
    directory = owned_work_path(args.assets)
    for asset in ASSETS:
        fetch(f"https://huggingface.co/{REPOSITORY}/resolve/{REVISION}/{asset['path']}", directory / asset["path"], asset)
    if args.wheelhouse:
        wheelhouse = owned_work_path(args.wheelhouse)
        manifest = json.loads((Path(__file__).with_name("s4-static-embeddings-dependencies.json")).read_text())
        for wheel in manifest[args.wheel_platform]:
            # Immutable file/hash pinned; PyPI lookup is preparation only.
            url = wheel.get("url")
            if not url:
                with urllib.request.urlopen(f"https://pypi.org/pypi/{wheel['package']}/{wheel['version']}/json", timeout=30) as response:
                    package = json.load(response)
                published = next(row for row in package["urls"] if row["filename"] == wheel["filename"])
                if published["digests"]["sha256"] != wheel["sha256"]:
                    raise ValueError("Published wheel hash mismatch")
                url = published["url"]
            if not url.startswith("https://files.pythonhosted.org/"):
                raise ValueError("Untrusted wheel host")
            fetch(url, wheelhouse / wheel["filename"], wheel)
    print("PREPARED: pinned public Model2Vec assets; optional pinned wheels. Inference has not run.", flush=True)


def offline_guard() -> dict:
    for name in ["HF_HUB_OFFLINE", "TRANSFORMERS_OFFLINE", "HF_HUB_DISABLE_TELEMETRY", "DO_NOT_TRACK"]:
        os.environ[name] = "1"
    os.environ["TOKENIZERS_PARALLELISM"] = "false"

    def audit(event, arguments):
        if event in {"socket.connect", "socket.getaddrinfo", "urllib.Request", "http.client.connect"}:
            OFFLINE_EVENTS.append(event)
            raise RuntimeError("Offline spike forbids network operations")

    sys.addaudithook(audit)
    blocked = False
    try:
        socket.getaddrinfo("huggingface.co", 443)
    except RuntimeError:
        blocked = True
    if not blocked:
        raise AssertionError("Offline guard self-test did not block DNS")
    OFFLINE_EVENTS.clear()  # The self-test is not a model-operation network attempt.
    return {"python_network_guard_self_test": "BLOCKED_BEFORE_DNS", "hf_offline": True,
            "native_network_proof": "NOT ESTABLISHED by Python guard; external native Linux strace or Windows-specific tracing evidence required"}


def memory() -> dict:
    if sys.platform == "win32":
        from ctypes import wintypes

        class Counters(ctypes.Structure):
            _fields_ = [("cb", wintypes.DWORD), ("PageFaultCount", wintypes.DWORD)] + [
                (name, ctypes.c_size_t) for name in ["PeakWorkingSetSize", "WorkingSetSize", "QuotaPeakPagedPoolUsage",
                "QuotaPagedPoolUsage", "QuotaPeakNonPagedPoolUsage", "QuotaNonPagedPoolUsage", "PagefileUsage",
                "PeakPagefileUsage", "PrivateUsage", "PrivateWorkingSetSize", "SharedCommitUsage"]]

        value = Counters()
        value.cb = ctypes.sizeof(value)
        get_current = ctypes.windll.kernel32.GetCurrentProcess
        get_current.restype = wintypes.HANDLE
        query = ctypes.windll.psapi.GetProcessMemoryInfo
        query.argtypes = [wintypes.HANDLE, ctypes.c_void_p, wintypes.DWORD]
        if not query(get_current(), ctypes.byref(value), value.cb):
            return {"status": "UNAVAILABLE"}
        return {"rss_bytes": value.WorkingSetSize, "os_peak_rss_bytes": value.PeakWorkingSetSize,
                "private_commit_bytes": value.PrivateUsage, "private_working_set_bytes": value.PrivateWorkingSetSize}
    if sys.platform.startswith("linux"):
        values = {}
        for line in Path("/proc/self/status").read_text().splitlines():
            key, _, value = line.partition(":")
            if key in {"VmRSS", "VmHWM", "VmSize"}:
                values[key] = int(value.split()[0]) * 1024
        return {"rss_bytes": values.get("VmRSS"), "os_peak_rss_bytes": values.get("VmHWM"), "virtual_bytes": values.get("VmSize")}
    return {"status": "UNAVAILABLE"}


class MemorySampler:
    def __init__(self):
        self.samples = []
        self.stopped = threading.Event()
        self.thread = threading.Thread(target=self.run, daemon=True)
        self.started = time.perf_counter()

    def run(self):
        while not self.stopped.is_set():
            self.samples.append({"elapsed_ms": (time.perf_counter() - self.started) * 1000, **memory()})
            self.stopped.wait(0.05)

    def __enter__(self):
        self.thread.start()
        return self

    def __exit__(self, *args):
        self.stopped.set()
        self.thread.join()
        self.samples.append({"elapsed_ms": (time.perf_counter() - self.started) * 1000, **memory()})


def graph_nodes(graph):
    import onnx
    for node in graph.node:
        yield node
        for attribute in node.attribute:
            if attribute.type == onnx.AttributeProto.GRAPH:
                yield from graph_nodes(attribute.g)


def graph_initializers(graph):
    import onnx
    yield from graph.initializer
    for node in graph.node:
        for attribute in node.attribute:
            if attribute.type == onnx.AttributeProto.GRAPH:
                yield from graph_initializers(attribute.g)


def graph_info(model) -> dict:
    import onnx
    if any(value.external_data for value in graph_initializers(model.graph)):
        raise ValueError("This pinned model must have no external-data files")
    operators = collections.Counter(node.op_type for node in graph_nodes(model.graph))
    if any(node.domain not in {"", "ai.onnx", "com.microsoft"} for node in graph_nodes(model.graph)):
        raise ValueError("Unexpected custom operator domain")
    return {"ir_version": model.ir_version,
            "opsets": [{"domain": value.domain, "version": value.version} for value in model.opset_import],
            "operators_including_subgraphs": dict(operators),
            "inputs": [{"name": value.name, "dtype": value.type.tensor_type.elem_type,
                        "shape": [dimension.dim_value or dimension.dim_param for dimension in value.type.tensor_type.shape.dim]} for value in model.graph.input],
            "outputs": [value.name for value in model.graph.output],
            "initializers": [{"name": value.name, "dtype": value.data_type, "shape": list(value.dims)} for value in graph_initializers(model.graph)]}


def tokenizer_for(directory: Path):
    from tokenizers import Tokenizer
    value = Tokenizer.from_file(str(directory / "tokenizer.json"))
    value.no_padding()
    value.no_truncation()
    return value


def token_ids(tokenizer, text: str) -> list[int]:
    # Model2Vec averages ordinary vocabulary rows; unlike a contextual encoder,
    # BOS/EOS are excluded. The pinned Unigram model has unk_id=1.
    if not text.strip():
        raise ValueError("Empty Model2Vec input; no fabricated zero vector")
    ids = [value for value in tokenizer.encode(text, add_special_tokens=False).ids if value != 1]
    if not ids:
        raise ValueError("No usable Model2Vec tokens; no fabricated zero vector")
    if any(value < 0 or value >= 500353 for value in ids):
        raise ValueError("Token id outside pinned embedding table (including appended special tokens)")
    return ids


def fixture(directory: Path) -> dict:
    tokenizer = tokenizer_for(directory)
    model_json = json.loads((directory / "tokenizer.json").read_text())
    if model_json["model"]["unk_id"] != 1:
        raise ValueError("Unexpected pinned unknown-token semantics")
    bases = {
        "he": ("כיצד שומרים מסמך מקורי במחשב בלי חיבור לרשת?", "זהו טקסט בדיקה מלאכותי בעברית. המחשב שומר מידע מקומי ומאפשר חיפוש במסמך המקורי. בדיקה זו אינה ציטוט מספר ואינה תשובה מוסמכת."),
        "en": ("How can an original document remain available without a network?", "This is an artificial test document in English. Local storage retains the original source and permits ordinary literal search. These words are generated benchmark inputs rather than authoritative evidence."),
        "arc": ("מאי טעמא בעינן למיבדק מילתא דא?", "האי מילתא דבדיקותא היא ולא מימרא דמקור. בעינן למיבדק לישנא ולמיחזי אי איכא מילי דמתאימן. טקסטא דא איתיה לבדיקה מלאכותית ולא לפסק הלכה.")}
    inputs = []
    for language, (question, passage) in bases.items():
        for number in range(10):
            pair_id = f"{language}-{number:02d}"
            query = question + f" בדיקה {number}" if language != "en" else question + f" test {number}"
            document = passage
            while len(token_ids(tokenizer, document)) < 110:
                document += " " + passage
            document += f" [{number}]"
            for role, text in [("query", query), ("document", document)]:
                ids = token_ids(tokenizer, text)
                inputs.append({"id": pair_id + ":" + role, "pair_id": pair_id, "lang": language,
                               "role": role, "text": text, "token_ids": ids, "tokens": len(ids)})
    for invalid in ["", "   "]:
        try:
            token_ids(tokenizer, invalid)
        except ValueError:
            pass
        else:
            raise AssertionError("Empty/out-of-vocabulary input guard did not reject")
    return {"label": "SILVER", "provenance": "Agent-generated synthetic Hebrew/English/Aramaic strings; no human ground truth",
            "pairs": 30, "inputs": inputs, "query_prompt": "", "document_prompt": "",
            "add_special_tokens": False, "unknown_id_removed": 1, "no_truncation": True,
            "padding": "none; flattened int64 ids with per-input start offsets",
            "empty_or_out_of_vocabulary_policy": "reject explicitly before inference"}


def summary(values):
    return {"count": len(values), "mean_ms": statistics.mean(values), "median_ms": statistics.median(values),
            "p95_ms": sorted(values)[math.ceil(len(values) * 0.95) - 1], "min_ms": min(values),
            "max_ms": max(values), "sample_sd_ms": statistics.stdev(values)}


def hardware() -> dict:
    value = {"logical_cpus_visible": os.cpu_count(), "processor": platform.processor(), "machine": platform.machine()}
    if sys.platform == "win32":
        from ctypes import wintypes
        class MemoryStatus(ctypes.Structure):
            _fields_ = [("length", wintypes.DWORD), ("load", wintypes.DWORD)] + [
                (name, ctypes.c_ulonglong) for name in ["total", "available", "total_page", "available_page", "total_virtual", "available_virtual", "available_extended"]]
        status = MemoryStatus()
        status.length = ctypes.sizeof(status)
        if not ctypes.windll.kernel32.GlobalMemoryStatusEx(ctypes.byref(status)):
            raise OSError("Actual Windows physical RAM unavailable")
        value.update({"MemTotalBytes": status.total, "MemAvailableBytes": status.available,
                      "native_cpu_details": "See Windows owned-supervisor CIM hardware record"})
    if sys.platform.startswith("linux"):
        for line in Path("/proc/cpuinfo").read_text().splitlines():
            if line.startswith("model name"):
                value["cpu_model"] = line.partition(":")[2].strip()
                break
        for line in Path("/proc/meminfo").read_text().splitlines():
            name, _, amount = line.partition(":")
            if name in {"MemTotal", "MemAvailable"}:
                value[name + "Bytes"] = int(amount.split()[0]) * 1024
        for filename, key in [("cpu.max", "cgroup_cpu_quota"), ("memory.max", "cgroup_ram_bytes")]:
            candidate = Path("/sys/fs/cgroup") / filename
            value[key] = candidate.read_text().strip() if candidate.exists() else None
    return value


def feeds(inputs, batch_size):
    import numpy as np
    for start in range(0, len(inputs), batch_size):
        batch = inputs[start:start + batch_size]
        flat, offsets = [], []
        for entry in batch:
            offsets.append(len(flat))
            flat.extend(entry["token_ids"])
        yield {"input_ids": np.array(flat, dtype=np.int64), "offsets": np.array(offsets, dtype=np.int64)}


def worker(args) -> None:
    guard = offline_guard()
    import numpy as np
    import onnxruntime as ort
    if ort.__version__ != "1.23.1":
        raise ValueError("ORT runtime version differs from pinned spike")
    inputs = json.loads(Path(args.fixture).read_text())["inputs"]
    options = ort.SessionOptions()
    options.intra_op_num_threads = args.threads
    options.inter_op_num_threads = 1
    options.execution_mode = ort.ExecutionMode.ORT_SEQUENTIAL
    options.graph_optimization_level = ort.GraphOptimizationLevel.ORT_ENABLE_ALL
    options.enable_mem_pattern = True
    options.enable_cpu_mem_arena = True
    measured = []
    with MemorySampler() as sampler:
        token_start = time.perf_counter()
        tokenizer = tokenizer_for(Path(args.assets))
        tokenizer_load_ms = (time.perf_counter() - token_start) * 1000
        token_times = []
        for repetition in range(-3, 30):
            started = time.perf_counter()
            ids = [token_ids(tokenizer, entry["text"]) for entry in inputs]
            elapsed = (time.perf_counter() - started) * 1000
            if ids != [entry["token_ids"] for entry in inputs]:
                raise AssertionError("Tokenization changed from frozen exact input ids")
            if repetition >= 0:
                token_times.append(elapsed)
        started = time.perf_counter()
        session = ort.InferenceSession(args.model, sess_options=options, providers=["CPUExecutionProvider"])
        load_ms = (time.perf_counter() - started) * 1000
        session.disable_fallback()
        if session.get_providers() != ["CPUExecutionProvider"]:
            raise AssertionError("Unexpected non-CPU execution provider")
        if [value.name for value in session.get_inputs()] != ["input_ids", "offsets"]:
            raise AssertionError("Unexpected pinned ONNX input convention")
        vectors = None
        for name, chosen, batch in [("single_query", inputs[:1], 1), ("30_pairs_batch1", inputs, 1), ("30_pairs_batch8", inputs, 8)]:
            feed_list = list(feeds(chosen, batch))
            payload_sha = hashlib.sha256(b"".join(value[key].tobytes() for value in feed_list for key in ["input_ids", "offsets"])).hexdigest()
            timings = []
            for repetition in range(-3, 30):
                start = time.perf_counter()
                output = np.concatenate([session.run(["embeddings"], feed)[0] for feed in feed_list], axis=0)
                elapsed = (time.perf_counter() - start) * 1000
                if output.shape != (len(chosen), 256) or not np.isfinite(output).all():
                    raise AssertionError("Invalid known-vector output/dimension")
                norms = np.linalg.norm(output, axis=1)
                if not np.allclose(norms, 1, rtol=0, atol=2e-6):
                    raise AssertionError("Output normalization/zero-vector failure")
                if repetition >= 0:
                    timings.append(elapsed)
            measured.append({"profile": name, "batch_size": batch, "embedding_input_count": len(chosen), "warmups": 3,
                             "timed_repetitions": 30, "feed_arrays_sha256": payload_sha,
                             "timings_ms": timings, "summary": summary(timings)})
            if name == "30_pairs_batch8":
                vectors = output
        # The session is still alive for the final residency sample; process exit
        # then releases the model before the next flavor starts.
    report = {"model_sha256": digest(Path(args.model)), "model_bytes": Path(args.model).stat().st_size,
              "load_ms": load_ms, "worker_pid": os.getpid(), "threads": args.threads, "inter_op_threads": 1,
              "provider": session.get_providers(), "graph_optimization": "ORT_ENABLE_ALL",
              "tokenization": {"tokenizer_load_ms": tokenizer_load_ms, "warmups": 3,
                               "timed_repetitions": 30, "timings_ms": token_times, "summary": summary(token_times)},
              "cold_warm": "fresh worker/session; uncontrolled filesystem cache; three per-profile warmups",
              "measurements": measured, "output_vectors": vectors.tolist(), "memory_samples": sampler.samples,
              "last_memory": memory(), "offline": guard, "model_operation_python_network_attempts": list(OFFLINE_EVENTS)}
    if OFFLINE_EVENTS:
        raise AssertionError("Model operation attempted Python network access")
    write_json(Path(args.output), report)


def run_worker(args, model: Path, fixture_path: Path, output: Path):
    command = [sys.executable, str(Path(__file__).resolve()), "_worker", "--model", str(model),
               "--fixture", str(fixture_path), "--output", str(output), "--threads", str(args.threads), "--assets", args.assets]
    result = subprocess.run(command, timeout=180, capture_output=True, text=True)
    if result.returncode:
        raise RuntimeError("Owned model worker failed: " + result.stderr[-2000:])
    return json.loads(output.read_text())


def benchmark(args) -> None:
    assets = owned_work_path(args.assets)
    verify_assets(assets)
    result = Path(args.results).resolve()
    if not (result.is_relative_to(PROJECT / "docs/BENCHMARKS") or result.is_relative_to(PROJECT / "work")):
        raise ValueError("Evidence must stay in project docs/BENCHMARKS/ or work/")
    result.mkdir(parents=True, exist_ok=False)
    guard = offline_guard()
    import numpy as np
    import onnx
    from onnxruntime.quantization import QuantType, quantize_dynamic
    config = json.loads((assets / "config.json").read_text())
    if config["hidden_dim"] != 256 or config["normalize"] is not True or any(config[key] is not None for key in ["apply_pca", "apply_zipf", "sif_coefficient"]):
        raise AssertionError("Unexpected pinned Model2Vec semantics")
    fp32 = assets / "onnx/model.onnx"
    derived = assets / "s4-derived-gather-uint8.onnx"
    if derived.exists():
        raise ValueError("Refusing to overwrite previous derived quantized artifact")
    with MemorySampler() as preparation_memory:
        start = time.perf_counter()
        # ORT's Gather handler uses activation quantization (UINT8), rather than
        # the weight_type path used by MatMul. Declare the actual format.
        quantize_dynamic(str(fp32), str(derived), op_types_to_quantize=["Gather"], weight_type=QuantType.QUInt8,
                         per_channel=False, reduce_range=False, extra_options={"EnableSubgraph": True})
        quantization_ms = (time.perf_counter() - start) * 1000
        model = onnx.load(str(derived), load_external_data=False)
        int8_graph = graph_info(model)
        tables = [value for value in graph_initializers(model.graph) if list(value.dims) == [500353, 256]]
        if len(tables) != 1 or tables[0].data_type != onnx.TensorProto.UINT8:
            raise AssertionError("The actual embedding table was not quantized to UINT8")
        del tables, model
        gc.collect()
        model = onnx.load(str(fp32), load_external_data=False)
        fp32_graph = graph_info(model)
        table = next(value for value in model.graph.initializer if list(value.dims) == [500353, 256])
        matrix = onnx.numpy_helper.to_array(table)
        data = fixture(assets)
        expected = []
        for entry in data["inputs"]:
            vector = matrix[entry["token_ids"]].mean(axis=0)
            vector /= max(float(np.linalg.norm(vector)), 1e-12)
            expected.append(vector.copy())
        expected = np.stack(expected)
        del matrix, table, model
        gc.collect()
    fixture_path = result / "inputs.json"
    write_json(fixture_path, data)
    fp = run_worker(args, fp32, fixture_path, result / "fp32.json")
    quant = run_worker(args, derived, fixture_path, result / "uint8.json")
    fp_vectors = np.array(fp["output_vectors"], dtype=np.float32)
    quant_vectors = np.array(quant["output_vectors"], dtype=np.float32)
    if not np.allclose(fp_vectors, expected, rtol=1e-5, atol=2e-6):
        raise AssertionError("Official FP32 ONNX disagrees with pinned mean-pooling/L2 NumPy reference")
    cosine = np.einsum("ij,ij->i", fp_vectors, quant_vectors)
    differences = np.abs(fp_vectors - quant_vectors)
    similarities_fp = fp_vectors[::2] @ fp_vectors[1::2].T
    similarities_int8 = quant_vectors[::2] @ quant_vectors[1::2].T
    configuration = {"threads": args.threads, "inter_op_threads": 1, "inference_provider": "CPUExecutionProvider",
                     "vocabulary_rows": 500353, "dimensions": 256, "pooling": "mean of non-UNK ordinary tokens",
                     "output_normalization": "official ONNX ReduceL2+Clip+Div", "add_special_tokens": False,
                     "truncation": False, "quantization": {"operation": "dynamic Gather including Loop subgraph",
                     "requested_weight_type": "QUInt8", "actual_embedding_table_dtype": "UINT8",
                     "activation_type_effective_default": "QUInt8 (GatherQuant uses activation quantization)",
                     "per_channel": False, "reduce_range": False},
                     "models_simultaneously_resident": 1, "warmups": 3, "timed_repetitions": 30}
    report = {"status": "MEASURED_PARTIAL", "experiment": "static_embedding_component", "execution_environment": "CODEX_CLOUD" if sys.platform.startswith("linux") else "GITHUB_WINDOWS_RUNNER" if os.environ.get("GITHUB_ACTIONS") == "true" else "OTHER_CLOUD_OR_LOCAL",
              "classification": "SILVER static Model2Vec component timings/parity; NOT transformer reranker or GOLD/domain quality evidence; NOT target16GB performance",
              "recorded_utc": dt.datetime.now(dt.timezone.utc).isoformat(), "platform": platform.platform(),
              "python": sys.version, "benchmark_parent_pid": os.getpid(), "hardware": hardware(),
              "model": {"repository": REPOSITORY, "revision": REVISION, "license": "MIT", "assets": ASSETS},
              "dependencies": {item.metadata["Name"]: item.version for item in importlib.metadata.distributions()},
              "source_sha256": digest(Path(__file__)), "input_sha256": digest(fixture_path),
              "dependency_manifest_sha256": digest(Path(__file__).with_name("s4-static-embeddings-dependencies.json")),
              "configuration": configuration, "configuration_sha256": hashlib.sha256(json_bytes(configuration)).hexdigest(),
              "graphs": {"fp32": fp32_graph, "uint8": int8_graph},
              "quantization": {"duration_ms": quantization_ms, "artifact_bytes": derived.stat().st_size,
              "artifact_sha256": digest(derived), "preparation_memory_samples": preparation_memory.samples},
              "numerical_parity": {"fp32_vs_numpy_mean_l2": "PASS", "max_abs_difference_uint8": float(differences.max()),
              "mean_abs_difference_uint8": float(differences.mean()), "vector_cosines_min": float(cosine.min()),
              "vector_cosines_mean": float(cosine.mean()), "vector_cosines": cosine.tolist(),
              "query_document_similarity_max_abs_change": float(np.abs(similarities_fp - similarities_int8).max()),
              "synthetic_nearest_document_agreement": float(np.mean(similarities_fp.argmax(axis=1) == similarities_int8.argmax(axis=1))),
              "quality_claim": "NONE; agreement is numerical/synthetic, not recall/grounding/GOLD quality"},
              "cold_warm": "Model downloads/preparation separate; filesystem cache uncontrolled; sequential fresh flavor workers followed by warm repetitions",
              "offline": guard, "model_operation_python_network_attempts": list(OFFLINE_EVENTS),
              "not_tested": ["native Windows network trace; Python guard alone is insufficient", "human GOLD/retrieval recall", "Torah/Aramaic meaning-preserving segmentation", "transformer reranking", "consumer target16GB", "controlled cold OS cache", "Windows execution unless this actual report is Windows"]}
    write_json(result / "summary.json", report)
    print(json.dumps({"status": report["status"], "results": str(result), "uint8_bytes": derived.stat().st_size,
                      "table_dtype": "UINT8", "cosine_min": report["numerical_parity"]["vector_cosines_min"], "offline_attempts": len(OFFLINE_EVENTS)}), flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    prep = commands.add_parser("prepare")
    prep.add_argument("--assets", default=str(PROJECT / "work/models/potion-multilingual-128M"))
    prep.add_argument("--wheelhouse")
    prep.add_argument("--wheel-platform", choices=["linux", "windows"], default="windows" if sys.platform == "win32" else "linux")
    bench = commands.add_parser("benchmark")
    bench.add_argument("--assets", default=str(PROJECT / "work/models/potion-multilingual-128M"))
    bench.add_argument("--results", required=True)
    bench.add_argument("--threads", type=int, required=True)
    child = commands.add_parser("_worker")
    for option in ["model", "fixture", "output"]:
        child.add_argument("--" + option, required=True)
    child.add_argument("--threads", type=int, required=True)
    child.add_argument("--assets", required=True)
    args = parser.parse_args()
    if hasattr(args, "threads") and not 1 <= args.threads <= 8:
        parser.error("Explicit experimental threads must be in [1,8]")
    if args.command == "prepare":
        prepare(args)
    elif args.command == "benchmark":
        benchmark(args)
    else:
        worker(args)


if __name__ == "__main__":
    main()
