"""Fetch OSF nodes from the OSF API with incremental updates.

- pagination
- optional token auth via OSF_TOKEN
- update detection by `date_modified`
- watermark-based incremental syncing
- prepend-only JSONL updates
- retry/backoff for transient failures.

Files created:
- osf_nodes.jsonl         # newest nodes prepended, existing order preserved
- osf_nodes_checkpoint.json  # sync state

Usage:
    python fetch_osf_nodes.py

Optional:
    export OSF_TOKEN="your-token-here"

"""

from __future__ import annotations

import json
import os
import sys
import time
from datetime import datetime
from pathlib import Path

import requests
from requests.adapters import HTTPAdapter
from urllib3.util.retry import Retry

from datasets.utils import console

BASE_URL = "https://api.osf.io/v2/nodes/"

REQUEST_TIMEOUT = 30
SAVE_EVERY_N_NEW = 100
SLEEP_BETWEEN_PAGES = 0.2
USER_AGENT = "osf-node-fetcher/1.0"


def build_session() -> requests.Session:
    """Build a requests Session with retry/backoff and optional OSF token auth."""
    session = requests.Session()

    retries = Retry(
        total=8,
        connect=8,
        read=8,
        backoff_factor=1.0,
        status_forcelist=[429, 500, 502, 503, 504],
        allowed_methods=["GET"],
        raise_on_status=False,
    )
    adapter = HTTPAdapter(max_retries=retries, pool_connections=20, pool_maxsize=20)
    session.mount("https://", adapter)
    session.mount("http://", adapter)

    headers = {
        "Accept": "application/vnd.api+json",
        "User-Agent": USER_AGENT,
    }

    token = os.getenv("OSF_TOKEN")
    if token:
        headers["Authorization"] = f"Bearer {token}"

    session.headers.update(headers)
    return session


def atomic_write_json(path: Path, obj: object) -> None:
    """Write a JSON object to a file atomically via a temporary file swap."""
    tmp = path.with_suffix(path.suffix + ".tmp")
    with tmp.open("w", encoding="utf-8") as f:
        json.dump(obj, f, ensure_ascii=False, indent=2)
    tmp.replace(path)


def load_checkpoint(checkpoint_file: Path) -> dict:
    """Load sync checkpoint from disk, or return defaults if none exists."""
    if checkpoint_file.exists():
        with checkpoint_file.open("r", encoding="utf-8") as f:
            return json.load(f)
    return {
        "high_watermark": None,
        "total_new_nodes_written": 0,
        "last_run_pages_fetched": 0,
        "last_run_new_nodes_written": 0,
        "started_at": int(time.time()),
        "last_saved_at": None,
    }


def save_checkpoint(
    checkpoint_file: Path,
    *,
    high_watermark: str | None,
    total_new_nodes_written: int,
    last_run_pages_fetched: int,
    last_run_new_nodes_written: int,
) -> None:
    """Persist current sync state to the checkpoint file."""
    checkpoint = {
        "high_watermark": high_watermark,
        "total_new_nodes_written": total_new_nodes_written,
        "last_run_pages_fetched": last_run_pages_fetched,
        "last_run_new_nodes_written": last_run_new_nodes_written,
        "last_saved_at": int(time.time()),
    }
    atomic_write_json(checkpoint_file, checkpoint)


def parse_osf_datetime(value: str | None) -> datetime | None:
    """Parse OSF API datetime string (ISO 8601, possibly Z-suffixed) into a datetime."""
    if not value or not isinstance(value, str):
        return None
    normalized = value.strip()
    if normalized.endswith("Z"):
        normalized = normalized[:-1] + "+00:00"
    try:
        return datetime.fromisoformat(normalized)
    except ValueError:
        return None


def extract_node_date_modified(node: dict) -> str | None:
    """Return the date_modified string from a node, checking attributes first."""
    attributes = node.get("attributes", {}) if isinstance(node, dict) else {}
    return attributes.get("date_modified", node.get("date_modified"))


def is_newer_date(candidate: str | None, baseline: str | None) -> bool:
    """Return True if candidate is strictly newer than baseline.

    Return None is treated as oldest.
    """
    candidate_dt = parse_osf_datetime(candidate)
    baseline_dt = parse_osf_datetime(baseline)
    if candidate_dt is None:
        return False
    if baseline_dt is None:
        return True
    return candidate_dt > baseline_dt


def load_existing_modification_index(
    jsonl_file: Path,
) -> tuple[dict[str, str | None], str | None]:
    """Scan the JSONL file and return a mapping of node ID to latest date_modified.

    Also return the overall watermark.
    """
    latest_modified_by_id: dict[str, str | None] = {}
    latest_watermark: str | None = None

    if not jsonl_file.exists():
        return latest_modified_by_id, latest_watermark

    with jsonl_file.open("r", encoding="utf-8") as f:
        for line_num, line in enumerate(f, start=1):
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
                node_id = obj.get("id")
                if not node_id:
                    continue

                node_modified = extract_node_date_modified(obj)

                previous = latest_modified_by_id.get(node_id)
                if node_id not in latest_modified_by_id or is_newer_date(
                    node_modified, previous,
                ):
                    latest_modified_by_id[node_id] = node_modified

                if is_newer_date(node_modified, latest_watermark):
                    latest_watermark = node_modified
            except json.JSONDecodeError:
                console.print(
                    f"Warning: skipping malformed JSONL line {line_num}",
                    file=sys.stderr,
                )

    return latest_modified_by_id, latest_watermark


def prepend_jsonl(nodes: list[dict], jsonl_file: Path) -> int:
    """Prepend new nodes to file, replacing any existing entries with the same ID."""
    if not nodes:
        return 0

    updated_ids = {node.get("id") for node in nodes if node.get("id")}

    written = 0
    tmp = jsonl_file.with_suffix(jsonl_file.suffix + ".tmp")
    with tmp.open("w", encoding="utf-8") as dst:
        for node in nodes:
            dst.write(json.dumps(node, ensure_ascii=False) + "\n")
            written += 1

        if jsonl_file.exists():
            with jsonl_file.open("r", encoding="utf-8") as src:
                for line in src:
                    stripped = line.strip()
                    if not stripped:
                        continue
                    try:
                        existing = json.loads(stripped)
                        if existing.get("id") in updated_ids:
                            continue
                    except json.JSONDecodeError:
                        pass
                    dst.write(line)

        dst.flush()
        os.fsync(dst.fileno())

    tmp.replace(jsonl_file)
    return written


def dedup_jsonl(jsonl_file: Path) -> int:
    """Remove duplicate IDs from a JSONL file, keeping the first occurrence."""
    if not jsonl_file.exists():
        return 0

    seen_ids: set[str] = set()
    kept = 0
    skipped = 0
    tmp = jsonl_file.with_suffix(jsonl_file.suffix + ".tmp")

    with (
        jsonl_file.open("r", encoding="utf-8") as src,
        tmp.open("w", encoding="utf-8") as dst,
    ):
        for line in src:
            stripped = line.strip()
            if not stripped:
                continue
            try:
                node_id = json.loads(stripped).get("id")
            except json.JSONDecodeError:
                dst.write(line)
                kept += 1
                continue
            if node_id and node_id in seen_ids:
                skipped += 1
                continue
            if node_id:
                seen_ids.add(node_id)
            dst.write(line)
            kept += 1

        dst.flush()
        os.fsync(dst.fileno())

    tmp.replace(jsonl_file)
    console.print(f"Dedup complete: kept {kept}, removed {skipped} duplicates.")
    return skipped


def extract_node_core_fields(node: dict) -> dict:
    """Extract fields (id, title, description, tags, category, dates) from a node."""
    attributes = node.get("attributes", {}) if isinstance(node, dict) else {}
    return {
        "id": node.get("id"),
        "title": attributes.get("title", node.get("title")),
        "description": attributes.get("description", node.get("description")),
        "tags": attributes.get("tags", node.get("tags", [])),
        "category": attributes.get("category", node.get("category")),
        "date_created": attributes.get("date_created", node.get("date_created")),
        "date_modified": attributes.get("date_modified", node.get("date_modified")),
    }


def extract_core_fields_jsonl(
    input_jsonl: Path = Path("osf_nodes.jsonl"),
    output_jsonl: Path = Path("osf_nodes_core_fields.jsonl"),
) -> int:
    """Extract selected node fields into a JSONL file."""
    console.print(f"Extracting core fields from {input_jsonl} to {output_jsonl}...")

    written = 0
    with (
        input_jsonl.open("r", encoding="utf-8") as src,
        output_jsonl.open("w", encoding="utf-8") as dst,
    ):
        for line_num, line in enumerate(src, start=1):
            line = line.strip()
            if not line:
                continue
            try:
                node = json.loads(line)
            except json.JSONDecodeError:
                console.print(
                    f"Warning: skipping malformed JSONL line {line_num} in {input_jsonl}",
                    file=sys.stderr,
                )
                continue

            extracted = extract_node_core_fields(node)
            dst.write(json.dumps(extracted, ensure_ascii=False) + "\n")
            written += 1

        dst.flush()
        os.fsync(dst.fileno())

    console.print(f"Extraction complete. {written} nodes processed.")
    return written


def fetch_page(session: requests.Session, url: str) -> dict:
    """Fetch a single page from the OSF API, handling 429 rate-limit responses."""
    resp = session.get(url, timeout=REQUEST_TIMEOUT)

    # Respect Retry-After if present and requests/urllib3 did not already handle it.
    if resp.status_code == requests.codes.too_many_requests:
        retry_after = resp.headers.get("Retry-After")
        delay = int(retry_after) if retry_after and retry_after.isdigit() else 30
        console.print(f"Rate limited (429). Sleeping for {delay}s...", file=sys.stderr)
        time.sleep(delay)
        resp = session.get(url, timeout=REQUEST_TIMEOUT)

    resp.raise_for_status()
    return resp.json()


def fetch_all_nodes(
    jsonl_file: Path = Path("osf_nodes.jsonl"),
    checkpoint_file: Path = Path("osf_nodes_checkpoint.json"),
) -> None:
    """Incrementally fetch all OSF nodes, prepending new/updated to the JSONL file."""
    session = build_session()

    console.print("Loading checkpoint...")
    checkpoint = load_checkpoint(checkpoint_file)
    latest_modified_by_id, jsonl_watermark = load_existing_modification_index(
        jsonl_file,
    )

    checkpoint_watermark = checkpoint.get("high_watermark")
    if is_newer_date(checkpoint_watermark, jsonl_watermark):
        high_watermark = checkpoint_watermark
    else:
        high_watermark = jsonl_watermark

    total_new_nodes_written = int(checkpoint.get("total_new_nodes_written", 0))
    pages_fetched = 0
    new_nodes_written_this_run = 0
    run_observed_latest_modified: str | None = None
    next_url: str | None = BASE_URL
    nodes_to_prepend: list[dict] = []

    console.print(f"Starting from: {next_url}")
    console.print(f"Known node ids in local JSONL: {len(latest_modified_by_id)}")
    console.print(f"High watermark (last synced date_modified): {high_watermark}")
    console.print(
        f"Total new/updated nodes written historically: {total_new_nodes_written}",
    )
    if os.getenv("OSF_TOKEN"):
        console.print("Using OSF_TOKEN for authenticated requests.")
    else:
        console.print("No OSF_TOKEN found; using unauthenticated requests.")

    stop_due_to_watermark = False

    high_watermark_dt = parse_osf_datetime(high_watermark)

    while next_url:
        try:
            payload = fetch_page(session, next_url)
            pages_fetched += 1

            data = payload.get("data", [])
            fresh_nodes = []

            for node in data:
                node_id = node.get("id")
                if not node_id:
                    continue

                node_modified = extract_node_date_modified(node)
                node_modified_dt = parse_osf_datetime(node_modified)

                if is_newer_date(node_modified, run_observed_latest_modified):
                    run_observed_latest_modified = node_modified

                # API ordering is newest -> oldest. Once we hit older-than-watermark
                # items, remaining pages cannot contain updates for this sync.
                if (
                    high_watermark_dt is not None
                    and node_modified_dt is not None
                    and node_modified_dt < high_watermark_dt
                ):
                    stop_due_to_watermark = True
                    break

                if node_id in latest_modified_by_id:
                    known_modified = latest_modified_by_id[node_id]
                    if not is_newer_date(node_modified, known_modified):
                        continue

                latest_modified_by_id[node_id] = node_modified
                fresh_nodes.append(node)

            if fresh_nodes:
                nodes_to_prepend.extend(fresh_nodes)
                just_written = len(fresh_nodes)
                new_nodes_written_this_run += just_written
                total_new_nodes_written += just_written

                console.print(
                    f"Page {pages_fetched}: got {len(data)} nodes, "
                    f"wrote {just_written} new/updated, "
                    f"total unique={len(latest_modified_by_id)}",
                )

                if new_nodes_written_this_run % SAVE_EVERY_N_NEW < just_written:
                    save_checkpoint(
                        checkpoint_file,
                        high_watermark=high_watermark,
                        total_new_nodes_written=total_new_nodes_written,
                        last_run_pages_fetched=pages_fetched,
                        last_run_new_nodes_written=new_nodes_written_this_run,
                    )
                    console.print("Checkpoint saved.")
            else:
                console.print(
                    f"Page {pages_fetched}: got {len(data)} nodes, "
                    f"wrote 0 new/updated, total unique={len(latest_modified_by_id)}",
                )

            if stop_due_to_watermark:
                next_url = None
            else:
                next_url = payload.get("links", {}).get("next")

            save_checkpoint(
                checkpoint_file,
                high_watermark=high_watermark,
                total_new_nodes_written=total_new_nodes_written,
                last_run_pages_fetched=pages_fetched,
                last_run_new_nodes_written=new_nodes_written_this_run,
            )

            if next_url:
                time.sleep(SLEEP_BETWEEN_PAGES)

        except KeyboardInterrupt:
            console.print("\nInterrupted by user. Saving checkpoint...")
            save_checkpoint(
                checkpoint_file,
                high_watermark=high_watermark,
                total_new_nodes_written=total_new_nodes_written,
                last_run_pages_fetched=pages_fetched,
                last_run_new_nodes_written=new_nodes_written_this_run,
            )
            raise

        except Exception as e:
            console.print(f"Error: {e}", file=sys.stderr)
            console.print("Saving checkpoint before exit...", file=sys.stderr)
            save_checkpoint(
                checkpoint_file,
                high_watermark=high_watermark,
                total_new_nodes_written=total_new_nodes_written,
                last_run_pages_fetched=pages_fetched,
                last_run_new_nodes_written=new_nodes_written_this_run,
            )
            sys.exit(1)

    if is_newer_date(run_observed_latest_modified, high_watermark):
        high_watermark = run_observed_latest_modified

    actually_prepended = prepend_jsonl(nodes_to_prepend, jsonl_file)

    save_checkpoint(
        checkpoint_file,
        high_watermark=high_watermark,
        total_new_nodes_written=total_new_nodes_written,
        last_run_pages_fetched=pages_fetched,
        last_run_new_nodes_written=new_nodes_written_this_run,
    )

    console.print("\nFinished.")
    if stop_due_to_watermark:
        console.print(
            "Stopped early after reaching nodes older than the high watermark.",
        )
    console.print(f"Pages fetched this run: {pages_fetched}")
    console.print(f"New/updated nodes written this run: {new_nodes_written_this_run}")
    console.print(f"Nodes prepended to JSONL this run: {actually_prepended}")
    console.print(f"JSONL file: {jsonl_file}")
    console.print(f"High watermark now: {high_watermark}")
    console.print(f"Checkpoint: {checkpoint_file}")


if __name__ == "__main__":
    fetch_all_nodes()
