#!/usr/bin/env python3
"""Export LLM evaluation results to a long-form CSV without running the annotation app.

It reads the processed ``eval/<topic>/<condition>/evaluation_report.json`` files
together with the ``eval_schema_*.json`` schemas and the dataset metadata CSV,
and writes a CSV, with schema:

    annotator,run_id,topic,condition,agent,intervention,iter,qid,kind,
    description,severity,value,notes,<metadata columns...>

Run:
    python3 annotation_app/export_eval_csv.py            # CSV to stdout
    python3 annotation_app/export_eval_csv.py -o full.csv
"""

from __future__ import annotations

import argparse
import csv
import glob
import json
import re
import sys
from pathlib import Path

# ROOT is the project root (parent of annotation_app/), mirroring app.py.
ROOT = Path(__file__).resolve()
RESULTS = ROOT / "results"
EVAL = ROOT / "eval"
# The dataset metadata lives here per the project layout (may not exist yet).
DEFAULT_METADATA_FILE = ROOT / "dataset_metadata.csv"

ITER_DIR_RE = re.compile(r"^([^_]+(?:_[^_]+)*?)_([0-9]+)_([^_]+)_iter_([0-9]+)$")


# ── Schema loading ────────────────────────────────────────────────────────


def load_schemas() -> dict[str, dict]:
    """Discover eval_schema_*.json files; return {_by_condition, _fallback}.

    Filename ``eval_schema_<cond>.json`` → condition ``<cond>``.
    ``eval_schema.example.json`` is the fallback for conditions without a file.
    """
    by_condition: dict[str, dict] = {}
    fallback: dict | None = None
    for path in sorted(glob.glob(str(ROOT / "eval_schema_*.json"))):
        name = Path(path).stem  # eval_schema_negative
        m = re.match(r"^eval_schema_(.+)$", name)
        if not m:
            continue
        cond = m.group(1)
        try:
            with open(path) as f:
                by_condition[cond] = json.load(f)
        except Exception as e:
            print(f"warn: could not load {path}: {e}", file=sys.stderr)
    example = ROOT / "eval_schema.example.json"
    if example.exists():
        try:
            with open(example) as f:
                fallback = json.load(f)
        except Exception:
            fallback = None
    return {"_by_condition": by_condition, "_fallback": fallback or {}}


def schema_for(schemas: dict, condition: str, topic: str) -> dict | None:
    cond_map = schemas["_by_condition"].get(condition, {})
    if topic in cond_map:
        return cond_map[topic]
    fb = schemas["_fallback"]
    return fb.get(topic)


# ── Run discovery ─────────────────────────────────────────────────────────


def discover_runs() -> list[dict]:
    """Walk results/ and return one record per iter_* directory.

    Layout: results/<topic>/<condition>/<agent>/<intervention>/<topic>_<intervention>_<agent>_iter_<N>/
    """
    runs: list[dict] = []
    if not RESULTS.exists():
        return runs
    for topic_dir in sorted(p for p in RESULTS.iterdir() if p.is_dir()):
        for cond_dir in sorted(p for p in topic_dir.iterdir() if p.is_dir()):
            for agent_dir in sorted(p for p in cond_dir.iterdir() if p.is_dir()):
                for interv_dir in sorted(p for p in agent_dir.iterdir() if p.is_dir()):
                    for iter_dir in sorted(
                        p for p in interv_dir.iterdir() if p.is_dir()
                    ):
                        m = ITER_DIR_RE.match(iter_dir.name)
                        if not m:
                            continue
                        iter_n = int(m.group(4))
                        run_id = "/".join(
                            [
                                topic_dir.name,
                                cond_dir.name,
                                agent_dir.name,
                                interv_dir.name,
                                str(iter_n),
                            ]
                        )
                        runs.append(
                            {
                                "id": run_id,
                                "topic": topic_dir.name,
                                "condition": cond_dir.name,
                                "agent": agent_dir.name,
                                "intervention": interv_dir.name,
                                "iter": iter_n,
                            }
                        )
    return runs


# ── LLM evaluation import ──────────────────────────────────────────────────


def evaluation_report_path(topic: str, condition: str) -> Path:
    return EVAL / topic / condition / "evaluation_report.json"


def extract_iter_evaluation(
    report: dict, agent: str, intervention: str, iter_n: int
) -> dict | None:
    """Pull a single iteration's `evaluation` block out of a processed evaluation_report.json."""
    try:
        iter_doc = (
            report.get("models", {})
            .get(agent, {})
            .get("conditions", {})
            .get(str(intervention), {})
            .get("iterations", {})
            .get(str(iter_n), {})
        )
    except AttributeError:
        return None
    ev = iter_doc.get("evaluation") if isinstance(iter_doc, dict) else None
    return ev if isinstance(ev, dict) else None


def llm_eval_model_name(condition: str | None = None) -> str | None:
    """Read eval_model from any evaluation_report.json under eval/, returning the first found."""
    for path in sorted(EVAL.glob("*/*/evaluation_report.json")):
        if condition and condition not in str(path):
            continue
        try:
            with open(path) as f:
                meta = json.load(f).get("metadata") or {}
            m = meta.get("eval_model")
            if m:
                return m
        except Exception:
            continue
    return None


def convert_llm_payload(eval_doc: dict) -> dict[str, dict]:
    """Convert one LLM evaluation doc to {questionId: {value, notes}}."""
    out: dict[str, dict] = {}
    for qid, q in (eval_doc.get("detections") or {}).items():
        status = q.get("status", "")
        notes = "\n".join(s for s in [q.get("explanation"), q.get("evidence")] if s)
        out[qid] = {"value": status, "notes": notes}
    for section in ("rubric_scores", "process_scores"):
        for qid, q in (eval_doc.get(section) or {}).items():
            score = q.get("score")
            value = "" if score is None else str(score)
            out[qid] = {"value": value, "notes": q.get("justification") or ""}
    return out


def import_llm_annotations(runs: list[dict]) -> tuple[dict[str, dict], list[str]]:
    """Build {run_id: {qid: {value, notes}}} from evaluation_report.json files.

    Returns (annotations, missing_run_ids). Mirrors app.import_llm_annotations but
    keeps everything in memory (no annotator file is written).
    """
    payload: dict[str, dict] = {}
    missing: list[str] = []
    reports: dict[tuple[str, str], dict | None] = {}
    for r in runs:
        key = (r["topic"], r["condition"])
        if key not in reports:
            p = evaluation_report_path(*key)
            if not p.exists():
                reports[key] = None
            else:
                try:
                    with open(p) as fh:
                        reports[key] = json.load(fh)
                except Exception as e:
                    print(f"warn: could not load {p}: {e}", file=sys.stderr)
                    reports[key] = None
        report = reports[key]
        if not report:
            missing.append(r["id"])
            continue
        eval_doc = extract_iter_evaluation(
            report, r["agent"], r["intervention"], r["iter"]
        )
        if not eval_doc:
            missing.append(r["id"])
            continue
        payload[r["id"]] = convert_llm_payload(eval_doc)
    return payload, missing


# ── Schema / metadata indexes ──────────────────────────────────────────────


def build_question_index(
    schemas: dict, runs: list[dict]
) -> dict[tuple[str, str], dict]:
    """Map (topic, qid) → schema question (kind, description, severity, scale)."""
    index: dict[tuple[str, str], dict] = {}
    seen_topic_cond: set[tuple[str, str]] = set()
    for r in runs:
        key = (r["topic"], r["condition"])
        if key in seen_topic_cond:
            continue
        seen_topic_cond.add(key)
        sch = schema_for(schemas, r["condition"], r["topic"])
        if not sch:
            continue
        shared = sch.get("shared", sch)
        for kind, items in (
            ("detection", shared.get("detections", [])),
            ("rubric", shared.get("rubric", [])),
            ("process", shared.get("process_criteria", [])),
        ):
            for q in items:
                qid = q.get("id")
                if not qid:
                    continue
                index.setdefault(
                    (r["topic"], qid),
                    {
                        "kind": kind,
                        "description": q.get("description"),
                        "severity": q.get("severity"),
                        "scale": q.get("scale"),
                    },
                )
    return index


def load_dataset_metadata(
    metadata_file: Path,
) -> tuple[list[str], dict[tuple[str, str], dict]]:
    """Read the dataset metadata CSV. Return (extra_columns, lookup).

    Lookup keys: ((domain, variant), row) and ((dataset, variant), row) so a run can be
    matched by either its `topic` (domain) or an exact dataset name.
    """
    if not metadata_file.exists():
        return [], {}
    try:
        with open(metadata_file, newline="") as f:
            reader = csv.DictReader(f)
            rows = list(reader)
            fieldnames = list(reader.fieldnames or [])
    except Exception as e:
        print(f"warn: could not read {metadata_file}: {e}", file=sys.stderr)
        return [], {}
    extra = [c for c in fieldnames if c not in {"variant"}]
    lookup: dict[tuple[str, str], dict] = {}
    for row in rows:
        variant = (row.get("variant") or "").strip()
        domain = (row.get("domain") or "").strip()
        dataset = (row.get("dataset") or "").strip()
        if domain:
            lookup[(domain, variant)] = row
        if dataset:
            lookup[(dataset, variant)] = row
    return extra, lookup


# ── CSV export ──────────────────────────────────────────────────────────────


def export_csv(
    out,
    annotator: str,
    annotations: dict[str, dict],
    runs: list[dict],
    schemas: dict,
    join_metadata: bool,
    metadata_file: Path,
) -> int:
    """Write the long-form CSV to the file-like `out`. Returns the number of data rows."""
    runs_by_id = {r["id"]: r for r in runs}
    qindex = build_question_index(schemas, runs)

    meta_cols: list[str] = []
    meta_lookup: dict[tuple[str, str], dict] = {}
    if join_metadata:
        meta_cols, meta_lookup = load_dataset_metadata(metadata_file)

    base_cols = [
        "annotator",
        "run_id",
        "topic",
        "condition",
        "agent",
        "intervention",
        "iter",
        "qid",
        "kind",
        "description",
        "severity",
        "value",
        "notes",
    ]
    header = base_cols + (meta_cols if join_metadata else [])

    w = csv.writer(out)
    w.writerow(header)

    meta_row_for_run: dict[str, dict] = {}
    if join_metadata:
        for run_id, run in runs_by_id.items():
            row = (
                meta_lookup.get((run["topic"], run["condition"]))
                or meta_lookup.get((run["topic"], ""))
                or {}
            )
            meta_row_for_run[run_id] = row

    n_rows = 0
    for run_id, qmap in annotations.items():
        run = runs_by_id.get(run_id)
        if not run:
            continue
        for qid, entry in qmap.items():
            if not isinstance(entry, dict):
                continue
            value = entry.get("value", "")
            notes = entry.get("notes", "")
            if (value is None or str(value).strip() == "") and not (
                notes and str(notes).strip()
            ):
                continue
            qmeta = qindex.get((run["topic"], qid), {})
            row = [
                annotator,
                run_id,
                run["topic"],
                run["condition"],
                run["agent"],
                run["intervention"],
                run["iter"],
                qid,
                qmeta.get("kind", ""),
                qmeta.get("description") or "",
                qmeta.get("severity") or "",
                "" if value is None else str(value),
                "" if notes is None else str(notes),
            ]
            if join_metadata:
                mrow = meta_row_for_run.get(run_id, {}) or {}
                row += [mrow.get(c, "") for c in meta_cols]
            w.writerow(row)
            n_rows += 1
    return n_rows


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument(
        "-o",
        "--output",
        default="-",
        help="Output CSV path ('-' for stdout, the default).",
    )
    parser.add_argument(
        "--annotator",
        default=None,
        help="Annotator name written to the CSV. "
        "Defaults to the eval_model from the reports (e.g. claude-sonnet-4-6).",
    )
    parser.add_argument(
        "--metadata",
        type=Path,
        default=DEFAULT_METADATA_FILE,
        help=f"Dataset metadata CSV (default: {DEFAULT_METADATA_FILE}).",
    )
    parser.add_argument(
        "--no-metadata",
        action="store_true",
        help="Do not join dataset metadata columns.",
    )
    args = parser.parse_args(argv)

    if not EVAL.exists():
        print(f"error: eval directory not found: {EVAL}", file=sys.stderr)
        return 2
    if not RESULTS.exists():
        print(f"error: results directory not found: {RESULTS}", file=sys.stderr)
        return 2

    schemas = load_schemas()
    runs = discover_runs()
    if not runs:
        print(f"error: no runs discovered under {RESULTS}", file=sys.stderr)
        return 2

    annotator = args.annotator or llm_eval_model_name() or "llm"
    annotations, missing = import_llm_annotations(runs)

    join_metadata = not args.no_metadata
    if join_metadata and not args.metadata.exists():
        print(
            f"warn: metadata file not found ({args.metadata}); "
            f"metadata columns will be omitted",
            file=sys.stderr,
        )

    close = False
    if args.output == "-":
        out = sys.stdout
    else:
        out = open(args.output, "w", newline="")
        close = True
    try:
        n_rows = export_csv(
            out,
            annotator,
            annotations,
            runs,
            schemas,
            join_metadata=join_metadata,
            metadata_file=args.metadata,
        )
    except BrokenPipeError:
        # Downstream consumer (e.g. `head`) closed the pipe; exit quietly.
        try:
            sys.stdout.close()
        except Exception:
            pass
        return 0
    finally:
        if close:
            out.close()

    print(
        f"wrote {n_rows} rows for {len(annotations)}/{len(runs)} runs "
        f"(annotator={annotator}, missing={len(missing)})"
        + (f" -> {args.output}" if args.output != "-" else ""),
        file=sys.stderr,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
