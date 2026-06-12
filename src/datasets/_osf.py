"""OSF API client and dataset loader."""

from __future__ import annotations

import json
import os
import shutil
import time
from collections import Counter
from concurrent.futures import ThreadPoolExecutor
from datetime import UTC, datetime
from pathlib import Path
from typing import Any
from urllib.parse import urlparse

import jsonlines as jsonl
import requests
import typer
from rich.markup import escape
from rich.progress import BarColumn, Progress, SpinnerColumn, TextColumn

from datasets import utils
from datasets.fetch_osf_nodes import extract_core_fields_jsonl, fetch_all_nodes
from datasets.intervention import IV
from datasets.utils import BM25Scorer, console

osf_app = typer.Typer(
    help="""OSF Tool - Search and download projects from the Open Science Framework.

Important: OSF may time out or rate limit requests if too many are made in a short period.
While there is fall back logic to handle some of these cases, it is recommended to use this tool
with a large timeout in case it hangs waiting for a response.""",
)

_INDEX_PATH = Path(os.getenv("OSF_INDEX_PATH", "osf_inverted_index.json"))
_OSF_CACHE_DIR = Path(
    os.getenv("OSF_CACHE_DIR", str(Path.home() / ".cache" / "datasets" / "osf")),
)
_OSF_INFO_LOG_LIMIT = None


class OSFClient(requests.Session):
    """Client for interacting with the OSF API v2."""

    BASE_URL = "https://api.osf.io/v2"
    METRICS_BASE_URL = "https://api.osf.io/_/metrics/query"
    OSF_DOMAINS = ("osf.io", "files.osf.io", "api.osf.io")

    def __init__(self, token: str | None = None) -> None:
        """Initialize OSF client.

        Args:
            token: Optional personal access token for authentication

        """
        super().__init__()
        self.token = token
        if token:
            self.headers.update({"Authorization": f"Bearer {token}"})
        self.headers.update({"Content-Type": "application/json"})

    def rebuild_auth(
        self,
        prepared_request: requests.PreparedRequest,
        response: requests.Response,
    ) -> None:
        """Only send OSF token to OSF domains — strip it for third-party storage."""
        host = urlparse(prepared_request.url).hostname or ""
        if any(
            host == domain or host.endswith(f".{domain}") for domain in self.OSF_DOMAINS
        ):
            prepared_request.headers["Authorization"] = f"Bearer {self.token}"
        else:
            # Strip auth header for non-OSF domains (e.g. GCS pre-signed URLs)
            prepared_request.headers.pop("Authorization", None)

    def _make_request(
        self,
        endpoint: str,
        params: dict[str, Any] | None = None,
    ) -> dict[str, Any]:
        """Make a GET request to the OSF API."""
        if endpoint.startswith("http"):
            url = endpoint  # already absolute
        else:
            url = f"{self.BASE_URL}/{endpoint.lstrip('/')}"
        max_retries = 5
        for attempt in range(max_retries):
            try:
                response = self.get(url, params=params)
                if response.status_code == requests.codes.too_many_requests:
                    retry_after = int(
                        response.headers.get("Retry-After", (attempt + 1) * 60),
                    )
                    console.print(
                        f"[yellow]Rate limited (429). Retrying in {retry_after}s "
                        f"(attempt {attempt + 1}/{max_retries})...[/yellow]",
                    )
                    time.sleep(retry_after)
                    continue
                response.raise_for_status()
                return response.json()
            except requests.exceptions.RequestException as e:
                console.print(f"[red]Error making request to {url}: {e}[/red]")
                raise
        # All retries exhausted on 429
        response.raise_for_status()
        return response.json()  # unreachable, but satisfies return type

    def _paginate(
        self,
        endpoint: str,
        params: dict[str, Any] | None = None,
        verbose: bool = False,
    ) -> list[dict[str, Any]]:
        """Fetch all pages of results from a paginated endpoint."""
        results = []
        next_url = None
        params = params or {}

        page = 1
        while True:
            if verbose:
                console.print(
                    f"[cyan]Fetching page {page} of results from {endpoint}...[/cyan]",
                )

            if next_url:
                # For pagination, use the full URL from links
                response = self.get(next_url)
                response.raise_for_status()
                data = response.json()
            else:
                data = self._make_request(endpoint, params)

            results.extend(data.get("data", []))

            if verbose:
                console.print(
                    f"[cyan]Fetched {len(results)} total items from {endpoint}...[/cyan]",
                )

            # Check for next page
            links = data.get("links", {})
            next_url = links.get("next")
            if not next_url:
                break
            page += 1

        return results

    def _preprocess(
        self,
        text: str,
        ns: tuple[int, ...] | None,
        ks: tuple[int, ...] | None,
    ) -> list[str]:
        """Generate n-grams and k-skip grams from a string of words.

        N-grams are contiguous sequences of n words. K-skip grams are sequences of
        n words where consecutive chosen words may be separated by up to k skipped
        words. N-grams are treated as a special case of k-skip grams with k=0.

        Args:
            text: Input string of words.
            ns:   Tuple of n values controlling sequence length (e.g. (2, 3)).
            ks:   Tuple of k values controlling max words skipped (e.g. (1, 2)).

        Returns:
            A list containing the original string alongside all generated n-grams
            and k-skip grams, with no duplicates.

        """
        words = text.lower().split()
        if ns is None and ks is None:
            return [" ".join(words)]

        results = set()
        for n in ns:
            for k in [0, *list(ks)]:
                stack = [(0, [])]
                while stack:
                    start, chosen = stack.pop()
                    if len(chosen) == n:
                        results.add(" ".join(words[i] for i in chosen))
                        continue
                    for i in range(start, len(words)):
                        if chosen and i - chosen[-1] - 1 > k:
                            break
                        stack.append((i + 1, [*chosen, i]))
        return list(results)

    def sort_nodes(
        self,
        nodes: list[dict[str, Any]],
        by: str,
        query: str,
    ) -> list[dict[str, Any]]:
        """In-place sort nodes by specified field."""
        sort_by_lower = by.lower()
        if sort_by_lower == "title":
            nodes.sort(
                key=lambda n: n.get("attributes", {}).get("title", "").lower(),
            )
        elif sort_by_lower == "category":
            nodes.sort(
                key=lambda n: n.get("attributes", {}).get("category", "").lower(),
            )
        elif sort_by_lower == "created":
            nodes.sort(
                key=lambda n: n.get("attributes", {}).get("date_created", ""),
                reverse=True,  # Most recent first
            )
        elif sort_by_lower == "relevance":
            # Calculate BM25 scores for relevance ranking
            if query:
                scorer = BM25Scorer()

                # Combine title and description for scoring
                documents = []
                for node in nodes:
                    attrs = node.get("attributes", {})
                    title_text = attrs.get("title", "")
                    desc_text = attrs.get("description", "")
                    tags_text = " ".join(attrs.get("tags", []))
                    # Combine with title weighted more heavily
                    doc_text = f"{title_text} {title_text} {desc_text} {tags_text}"
                    documents.append(doc_text)

                scores = scorer.score(query, documents)

                # Attach scores to nodes and sort
                for node, score in zip(nodes, scores, strict=True):
                    node["_bm25_score"] = score

                nodes.sort(key=lambda n: n.get("_bm25_score", 0.0), reverse=True)
            else:
                console.print(
                    "[yellow]Warning: Relevance sorting requires a query. "
                    "Results not sorted.[/yellow]",
                )
        else:
            console.print(
                f"[yellow]Warning: Unknown sort option '{by}'. "
                f"Valid options: title, category, created, relevance[/yellow]",
            )

    def search_nodes(
        self,
        title: str | None = None,
        description: str | None = None,
        tags: str | None = None,
        category: str | None = None,
        sort_by: str | None = None,
        limit: int | None = None,
    ) -> list[dict[str, Any]]:
        """Search for nodes (projects/components) on OSF.

        Args:
            title: Filter by title (substring match)
            description: Filter by description (substring match)
            tags: Filter by tags (substring match)
            category: Filter by category (exact match)
            sort_by: Sort results by: title, category, created, relevance
            limit: Minimum number of results to return

        Returns:
            List of node dictionaries

        """
        results = []
        search_tactics = [((1,), (0,)), ((2,), (0,)), ((3,), (0,)), (None, None)]
        while (not results or len(results) < limit) and search_tactics:
            params = {}
            ns, ks = search_tactics.pop()
            if title:
                params["filter[title]"] = self._preprocess(title, ns, ks)
            if description:
                params["filter[description]"] = self._preprocess(description, ns, ks)
            if tags:
                params["filter[tags][icontains]"] = [t.strip() for t in tags.split(",")]
            if category:
                params["filter[category]"] = category.strip()

            params = {k: v for k, v in params.items() if v}
            if not params or (len(params) == 1 and "filter[category]" in params):
                # If no effective filters, break to avoid fetching everything
                break

            console.print(
                f"[cyan]Searching OSF with filters: {escape(str(params))}[/cyan]",
            )
            results = self._paginate("nodes/", params)

        # Sort results if requested
        sort_query = ""
        if sort_by.lower() == "relevance":
            if title:
                sort_query = title
            elif description:
                sort_query += f" {description}"
        self.sort_nodes(results, sort_by, sort_query.strip())
        return results

    def get_nodes(self, node_ids: str | list[str]) -> list[dict[str, Any]]:
        """Get details for multiple nodes.

        Responses are cached on disk in a single JSON file at
        ``_OSF_CACHE_DIR/nodes.json`` mapping ``node_id`` to its API
        response. The cache is consulted serially first; only node IDs
        that miss the cache are fetched from the API in parallel, and
        successful responses are written back to the file.
        """
        if isinstance(node_ids, str):
            node_ids = [node_ids]

        if not node_ids:
            return []

        cache_path = _OSF_CACHE_DIR / "nodes.json"
        cache: dict[str, dict[str, Any]] = {}
        if cache_path.exists():
            try:
                with cache_path.open("r", encoding="utf-8") as f:
                    cache = json.load(f)
            except (json.JSONDecodeError, OSError):
                cache = {}

        results: dict[str, dict[str, Any]] = {}
        missing: list[str] = []
        for nid in node_ids:
            if nid in cache:
                results[nid] = cache[nid]
            else:
                missing.append(nid)

        if missing:
            max_workers = min(16, len(missing))
            with ThreadPoolExecutor(max_workers=max_workers) as executor:
                fetched = list(
                    executor.map(
                        lambda nid: (
                            nid,
                            self._make_request(
                                "nodes/", params={"filter[id]": nid}
                            ),
                        ),
                        missing,
                    ),
                )

            for nid, data in fetched:
                results[nid] = data
                cache[nid] = data

            try:
                cache_path.parent.mkdir(parents=True, exist_ok=True)
                with cache_path.open("w", encoding="utf-8") as f:
                    json.dump(cache, f)
            except OSError:
                pass

        return [results[nid] for nid in node_ids]

    def get_contributors(self, node_id: str) -> list[dict[str, Any]]:
        """Get contributors for a node."""
        return self._paginate(f"nodes/{node_id}/contributors/")

    def get_logs(
        self,
        node_id: str,
        limit: int,
    ) -> list[dict[str, Any]]:
        """Get logs (version history) for a node up to a maximum number of entries."""
        if limit is not None:
            data = self._make_request(
                f"nodes/{node_id}/logs/",
                params={"page[size]": min(limit, 100)},
            )
            return data.get("data", [])[:limit]
        return self._paginate(f"nodes/{node_id}/logs/")

    def get_fork_count(self, node_id: str) -> int:
        """Get the number of forks for a node."""
        data = self._make_request(
            f"nodes/{node_id}/forks/",
            params={"page[size]": 1},
        )
        meta = data.get("meta", {})
        total = meta.get("total")
        if isinstance(total, int):
            return total
        return len(self._paginate(f"nodes/{node_id}/forks/"))

    def get_total_file_downloads(
        self,
        node_id: str,
        provider: str = "osfstorage",
    ) -> int:
        """Get the total number of downloads across all files for a node."""
        files = self.get_files(node_id, provider=provider, recursive=True)

        total_downloads = 0
        for file_item, _depth in files:
            attrs = file_item.get("attributes", {})
            if attrs.get("kind") != "file":
                continue

            download_value = attrs.get("download_count")
            if download_value is None:
                download_value = attrs.get("downloads")
            if download_value is None:
                download_value = attrs.get("extra", {}).get("downloads")

            if isinstance(download_value, int):
                total_downloads += download_value

        return total_downloads

    def get_monthly_unique_visitors(self, node_id: str) -> int:
        """Get the total number of unique visitors for the last month."""
        data = self._make_request(
            f"{self.METRICS_BASE_URL}/node_analytics/{node_id}/month/",
        )
        unique_visits = (
            data.get("data", {}).get("attributes", {}).get("unique_visits", [])
        )

        total_unique_visitors = 0
        for item in unique_visits:
            count = item.get("count") if isinstance(item, dict) else None
            if isinstance(count, int):
                total_unique_visitors += count

        return total_unique_visitors

    def get_metrics(self, node_id: str) -> dict[str, int]:
        try:
            console.quiet = True
            fork_count = self.get_fork_count(node_id)
            total_file_downloads = self.get_total_file_downloads(node_id)
            monthly_unique_visitors = self.get_monthly_unique_visitors(node_id)
        except requests.exceptions.HTTPError as e:
            # Private project - metrics not accessible
            if e.response.status_code == requests.codes.forbidden:
                fork_count, total_file_downloads, monthly_unique_visitors = 0, 0, 0
            else:
                raise

        console.quiet = False
        return {
            "fork_count": fork_count,
            "total_file_downloads": total_file_downloads,
            "monthly_unique_visitors": monthly_unique_visitors,
        }

    def get_storage_providers(self, node_id: str) -> list[dict[str, Any]]:
        """Get storage providers for a node."""
        data = self._make_request(f"nodes/{node_id}/files/")
        return data.get("data", [])

    def has_files(
        self,
        node_id: str,
        provider: str = "osfstorage",
    ) -> bool:
        """Check whether a node has any files without fetching the full list.

        Results are cached in a global lookup at
        ``_OSF_CACHE_DIR/has_files.json`` mapping node_id to bool. Subsequent
        calls for the same node read from the cache before hitting the server.

        Args:
            node_id: Node ID
            provider: Storage provider name (default: osfstorage)

        Returns:
            True if the node has at least one file or folder, False otherwise.

        """
        cache_path = _OSF_CACHE_DIR / "has_files.json"
        cache: dict[str, bool] = {}
        if cache_path.exists():
            try:
                with cache_path.open("r", encoding="utf-8") as f:
                    cache = json.load(f)
            except (json.JSONDecodeError, OSError):
                cache = {}
            if node_id in cache:
                return bool(cache[node_id])

        endpoint = f"nodes/{node_id}/files/{provider}/"
        data = self._make_request(endpoint, params={"page[size]": 1})
        result = len(data.get("data", [])) > 0

        cache[node_id] = result
        try:
            cache_path.parent.mkdir(parents=True, exist_ok=True)
            with cache_path.open("w", encoding="utf-8") as f:
                json.dump(cache, f)
        except OSError:
            pass

        return result

    def get_files(
        self,
        node_id: str,
        provider: str = "osfstorage",
        path: str = "",
        recursive: bool = False,
    ) -> list[tuple[dict[str, Any], int]]:
        """Get files for a node from a specific storage provider.

        Args:
            node_id: Node ID
            provider: Storage provider name (default: osfstorage)
            path: Path within the provider (optional, for internal recursion)
            recursive: Whether to recursively traverse folders (only valid when path="")

        Returns:
            List of file/folder dictionaries if recursive=False,
            List of (file_dict, depth) tuples if recursive=True

        """
        if not recursive or path:
            if path:
                endpoint = f"nodes/{node_id}/files/{provider}/{path}/"
            else:
                endpoint = f"nodes/{node_id}/files/{provider}/"

            all_items = []
            data = self._make_request(endpoint)
            all_items.extend(data.get("data", []))

            while True:
                next_url = utils.normalize_path(data.get("links", {}).get("next"))
                if not next_url:
                    break
                data = self._make_request(next_url)
                all_items.extend(data.get("data", []))

            return [(item, 0) for item in all_items]  # always return (dict, depth)

        result: list[tuple[dict[str, Any], int]] = []
        seen_paths: set[str] = set()

        def traverse(items: list[dict[str, Any]], depth: int = 0) -> None:
            for item in items:
                result.append((item, depth))
                attributes = item.get("attributes", {})
                if attributes.get("kind") != "folder":
                    continue
                folder_path = utils.normalize_path(
                    attributes.get("path") or attributes.get("materialized_path"),
                )
                if not folder_path or folder_path in seen_paths:
                    continue
                seen_paths.add(folder_path)
                children = self.get_files(node_id, provider, path=folder_path)
                if children:
                    traverse([f for f, _ in children], depth=depth + 1)  # unpack tuples

        top_level = self.get_files(node_id, provider)
        traverse([f for f, _ in top_level])
        return result

    def download_file(self, download_url: str, output_path: Path) -> None:
        """Download a file from OSF.

        Args:
            download_url: URL to download from
            output_path: Local path to save the file

        """
        output_path.parent.mkdir(parents=True, exist_ok=True)

        response = self.get(download_url, stream=True)
        response.raise_for_status()

        total_size = int(response.headers.get("content-length", 0))

        with output_path.open("wb") as f:
            if total_size == 0:
                f.write(response.content)
            else:
                downloaded = 0
                for chunk in response.iter_content(chunk_size=8192):
                    if chunk:
                        f.write(chunk)
                        downloaded += len(chunk)

    def download_all_files(
        self,
        node_id: str,
        output_dir: Path,
        provider: str = "osfstorage",
        recursive: bool = True,
        override: bool = False,
        cache_dir: Path | None = None,
    ) -> int:
        """Download all files from a node, optionally recursing into folders.

        Files are first downloaded to a per-project cache directory and then
        copied to ``output_dir``. If a file is already present in the cache,
        the download is skipped and the cached copy is used directly.

        Args:
            node_id: Node ID
            output_dir: Directory to save files
            provider: Storage provider name
            recursive: Whether to recursively traverse folders (default: True)
            override: Whether to override existing files (default: False)
            cache_dir: Root cache directory (default: ``$OSF_CACHE_DIR`` or
                ``~/.cache/datasets/osf``)

        Returns:
            Number of files downloaded

        """
        count = 0
        skipped = 0
        output_dir.mkdir(parents=True, exist_ok=True)

        cache_root = cache_dir if cache_dir is not None else _OSF_CACHE_DIR
        cache_project_dir = cache_root / node_id / provider

        # Get file list to download
        files = self.get_files(node_id, provider, recursive=recursive)

        for file_dict, _ in files:
            attributes = file_dict.get("attributes", {})
            name = attributes.get("name", "unknown")
            materialized_path = utils.normalize_path(
                attributes.get("materialized_path"),
            )
            kind = attributes.get("kind")
            links = file_dict.get("links", {})
            if kind == "folder":
                if recursive:
                    # Recursively download folder contents
                    folder_path = output_dir / materialized_path
                    relative_name = folder_path.relative_to(output_dir)
                    console.print(
                        f"[blue]Entering folder: {relative_name}[/blue]",
                    )
                    folder_path.mkdir(parents=True, exist_ok=True)
                else:
                    console.print(f"[yellow]Skipping folder: {name}[/yellow]")
            elif kind == "file":
                download_url = links.get("download")
                if download_url and materialized_path:
                    file_path = output_dir / materialized_path
                    cache_path = cache_project_dir / materialized_path
                    if not override and file_path.exists():
                        console.print(
                            f"[yellow]Skipping existing file: {file_path}[/yellow]",
                        )
                        skipped += 1
                        continue
                    try:
                        if cache_path.exists():
                            console.print(
                                f"[cyan]Downloading: {cache_path.relative_to(cache_root)}[/cyan]",
                            )
                        else:
                            console.print(
                                f"[green]Downloading: {file_path}[/green]",
                            )
                            self.download_file(download_url, cache_path)
                        file_path.parent.mkdir(parents=True, exist_ok=True)
                        shutil.copy2(cache_path, file_path)
                        count += 1
                    except Exception as e:
                        console.print(f"[red]Failed to download {name}: {e}[/red]")
                else:
                    console.print(
                        f"[red]No download link for file: {name} "
                        f"(ID: {file_dict.get('id')})[/red]",
                    )
        return count, skipped


@osf_app.command("search")
def osf_search(
    ctx: typer.Context,
    search_term: str | None = typer.Argument(
        None,
        help="Search term (shortcut for --title)",
    ),
    title: str | None = typer.Option(
        None,
        "--title",
        "-t",
        help="Filter by title",
    ),
    description: str | None = typer.Option(
        None,
        "--description",
        "-d",
        help="Filter by description",
    ),
    tags: str | None = typer.Option(
        None,
        "--tags",
        help="Filter by tags (give as comma separated string)",
    ),
    limit: int | None = typer.Option(
        25,
        "--limit",
        "-l",
        help="Maximum number of results",
    ),
    sort_by: str | None = typer.Option(
        "relevance",
        "--sort-by",
        "-s",
        help="Sort results by: title, category, created, relevance",
    ),
) -> None:
    """Search for projects on the Open Science Framework.

    Examples:
        osf_tool.py search --title "reproducibility"
        osf_tool.py search --description "machine learning" --sort-by relevance
        osf_tool.py search --sort-by created --limit 20

    Sorting Options:
        relevance - Sort by BM25 relevance score (requires a query; default)
        title - Sort alphabetically by title
        category - Sort alphabetically by category
        created - Sort by creation date (newest first)

    """
    # Positional search_term acts as --title shortcut
    if search_term is not None and title is None:
        title = search_term

    category = None  # Temporarily disable category filtering
    client: OSFClient = ctx.obj["client"]

    def load_inverted_index(path: Path) -> dict[str, list[str]]:
        if not path.exists():
            return {}

        try:
            with path.open("r", encoding="utf-8") as f:
                return json.load(f)["index"]
        except json.JSONDecodeError, OSError:
            return {}

    def build_query_tokens() -> list[str]:
        tokens: list[str] = []
        if title:
            tokens.extend(utils.preprocess(title))
        if description:
            tokens.extend(utils.preprocess(description))
        if category:
            tokens.extend(utils.preprocess(category))
        if tags:
            for tag in tags.split(","):
                tokens.extend(utils.preprocess(tag.strip()))
        return tokens

    try:
        nodes: list[dict[str, Any]] = []
        inverted_index = load_inverted_index(_INDEX_PATH)
        query_tokens = build_query_tokens()
        use_index = bool(inverted_index and query_tokens)

        if use_index:
            token_hits: Counter[str] = Counter()
            for token in set(query_tokens):
                for node_id in inverted_index.get(token, []):
                    token_hits[node_id] += 1

            if token_hits:
                fetch_cap = max(limit * 5, limit) if limit else 200
                candidate_ids = [node_id for node_id, _ in token_hits.most_common()]
                candidate_ids = candidate_ids[:fetch_cap]

                with Progress(
                    SpinnerColumn(),
                    TextColumn("[progress.description]{task.description}"),
                    console=console,
                ) as progress:
                    progress.add_task(
                        description="Fetching OSF nodes...",
                        total=None,
                    )

                    nodes = client.get_nodes(candidate_ids)
                    nodes = [n.get("data")[0] for n in nodes if n.get("data")]
            else:
                nodes = []
        else:
            with Progress(
                SpinnerColumn(),
                TextColumn("[progress.description]{task.description}"),
                console=console,
            ) as progress:
                progress.add_task(description="Searching OSF...", total=None)

                nodes = client.search_nodes(
                    title=title,
                    description=description,
                    tags=tags,
                    category=category,
                    sort_by=sort_by,
                    limit=limit,
                )

        for n in nodes:
            if n.get("id") == IV.data_id:
                IV.enabled = True
                n["attributes"]["description"] += IV.add_description_str
                n["attributes"]["tags"] = IV.add_tags
                IV.enabled = False

        if use_index and nodes:
            sort_query = " ".join(s for s in [title, description, tags, category] if s)
            client.sort_nodes(nodes, sort_by, sort_query.strip())

        if not nodes:
            console.print("[yellow]No results found.[/yellow]")
            return

        for i, node in enumerate(nodes):
            if limit and i >= limit:
                break
            node["has_files"] = "Yes" if client.has_files(node.get("id", "")) else "No"

        console.print(
            f"\n[bold green]Found {len(nodes)} results "
            f"(showing {min(limit, len(nodes))})[/bold green]\n"
        )

        header = ["ID", "Category", "Created", "Files?", "Title"]
        console.print("\t".join(header))
        for i, node in enumerate(nodes):
            if limit and i >= limit:
                break

            node_id = node.get("id", "")
            attributes = node.get("attributes", {})

            title = attributes.get("title", "N/A")
            category = attributes.get("category", "N/A")
            date_created = attributes.get("date_created", "")
            has_files = node.get("has_files", "No")

            # Format date
            if date_created:
                try:
                    dt = datetime.fromisoformat(date_created)
                    date_created = dt.strftime("%Y-%m-%d")
                except ValueError:
                    pass

            row = [node_id, category, date_created, has_files, title]
            console.print("\t".join(row))

    except Exception as e:
        console.print(f"[red]Error: {e}[/red]")
        raise typer.Exit(1) from e


@osf_app.command("info")
def osf_info(
    ctx: typer.Context,
    project_id: str = typer.Argument(..., help="OSF project ID"),
) -> None:
    """Get detailed information about a specific project.

    Examples:
        osf_tool.py info abc12

    """
    IV.enable(project_id)

    client: OSFClient = ctx.obj["client"]

    def format_node_detail(
        node: dict[str, Any],
        contributors: list[dict[str, Any]],
        logs: list[dict[str, Any]],
        metrics: dict[str, int],
    ) -> str:
        """Format detailed node information."""
        attrs = node.get("attributes", {})
        description_text = attrs.get("description", "N/A")
        tags = attrs.get("tags", [])
        if IV.add_description_str:
            description_text += IV.add_description_str
            tags.extend(IV.add_tags)
        node_id = node.get("id", "N/A")

        lines = [
            f"[bold cyan]Project ID:[/bold cyan] {node_id}",
            f"[bold cyan]Title:[/bold cyan] {attrs.get('title', 'N/A')}",
            f"[bold cyan]Category:[/bold cyan] {attrs.get('category', 'N/A')}",
            f"[bold cyan]Description:[/bold cyan] {description_text.strip()}",
            f"[bold cyan]Created:[/bold cyan] {attrs.get('date_created', 'N/A')}",
            f"[bold cyan]Modified:[/bold cyan] {attrs.get('date_modified', 'N/A')}",
            f"[bold cyan]Tags:[/bold cyan] {', '.join(tags) if tags else ''}",
            f"[bold cyan]Forks:[/bold cyan] {metrics.get('fork_count', '')}",
            f"[bold cyan]Total file downloads:[/bold cyan] {metrics.get('total_file_downloads', '')}",
            f"[bold cyan]Unique visitors (last month):[/bold cyan] {metrics.get('monthly_unique_visitors', '')}",
        ]

        if contributors:
            lines.append("\n[bold cyan]Contributors:[/bold cyan]")
            for contrib in contributors:
                user_data = contrib.get("embeds", {}).get("users", {}).get("data", {})
                user_attrs = user_data.get("attributes", {})
                full_name = user_attrs.get("full_name", "Unknown").strip()
                bibliographic = contrib.get("attributes", {}).get(
                    "bibliographic",
                    False,
                )
                bib_marker = "*" if bibliographic else ""
                if IV.replace_creator:
                    full_name = IV.replace_creator.get(full_name, full_name)
                lines.append(f"  - {full_name}{bib_marker}")

        if logs:
            lines.append(
                "\n[bold cyan]Version history "
                f"(latest {len(logs)} entries):[/bold cyan]",
            )
            for log in logs:
                log_attrs = log.get("attributes", {})
                action = log_attrs.get("action", "unknown_action")
                date = log_attrs.get("date", "N/A")
                actor = utils.extract_actor(log)

                if IV.remove_creators:
                    actor = None
                actor_summary = f" by {actor}" if actor else ""
                lines.append(f"  - [{date}] {action}{actor_summary}")

        return "\n".join(lines)

    try:
        with Progress(
            SpinnerColumn(),
            TextColumn("[progress.description]{task.description}"),
            console=console,
        ) as progress:
            progress.add_task(description="Fetching project info...", total=None)

            nodes = client.get_nodes(project_id)[0]
            if not nodes or "data" not in nodes or not nodes["data"]:
                console.print(
                    f"[yellow]No project found with ID '{project_id}'[/yellow]",
                )
                return

            node = nodes.get("data", {})[0]
            contributors = []
            if not IV.remove_creators:
                contributors = client.get_contributors(project_id)
            logs = []
            if not IV.remove_version_history:
                logs = client.get_logs(project_id, _OSF_INFO_LOG_LIMIT)
            metrics = {}
            if not IV.remove_metrics:
                metrics = client.get_metrics(project_id)

        console.print(
            "\n"
            + format_node_detail(
                node,
                contributors,
                logs,
                metrics,
            ),
        )

    except Exception as e:
        console.print(f"[red]Error: {e}[/red]")
        raise typer.Exit(1) from e


@osf_app.command("fetch", hidden=True)
def osf_fetch_nodes(
    ctx: typer.Context,  # noqa: ARG001
    extract_metadata: bool = typer.Option(
        False,
        "-m",
        "--metadata",
        help="Whether to also extract metadata fields from OSF nodes.",
    ),
    jsonl_file: Path = typer.Option(
        Path("osf_nodes.jsonl"),
        "-o",
        "--output-file",
        help="Path to save fetched OSF nodes (JSONL format)",
    ),
    checkpoint_path: Path = typer.Option(
        Path("osf_nodes_checkpoint.json"),
        "-c",
        "--checkpoint",
        help="Path to save checkpoint for resuming fetches (JSON format)",
    ),
    metadata_file: Path = typer.Option(
        Path("osf_nodes_core_fields.jsonl"),
        "-od",
        "--metadata-file",
        help="Path to save extracted metadata (JSONL format, if --metadata is set)",
    ),
) -> None:
    """Fetch all nodes from the OSF API."""
    fetch_all_nodes(jsonl_file, checkpoint_path)
    if extract_metadata:
        extract_core_fields_jsonl(jsonl_file, metadata_file)


@osf_app.command("index", hidden=True)
def osf_index(
    ctx: typer.Context,  # noqa: ARG001
    osf_nodes_file: Path = typer.Option(
        Path("osf_nodes_core_fields.jsonl"),
        "-f",
        "--nodes-file",
        help="Path to pre-downloaded JSONL file of OSF nodes",
    ),
) -> None:
    """Build inverted index of metadata from a pre-downloaded JSONL file of OSF nodes.

    The inverted index is saved to ~/.datasets/osf_inverted_index.json.
    """

    def load_existing_index() -> tuple[dict[str, set[str]], datetime | None]:
        console.print(
            f"Loading existing inverted index from {_INDEX_PATH}...",
        )
        if not _INDEX_PATH.exists():
            return {}, None

        try:
            with _INDEX_PATH.open("r", encoding="utf-8") as f:
                payload = json.load(f)
        except json.JSONDecodeError, OSError:
            return {}, None

        if isinstance(payload, dict) and "index" in payload:
            raw_index = payload.get("index", {})
            last_built_raw = payload.get("last_built")
            last_built = parse_timestamp(last_built_raw) if last_built_raw else None
        else:
            raw_index = payload if isinstance(payload, dict) else {}
            last_built = None

        index: dict[str, set[str]] = {}
        for token, ids in raw_index.items():
            if isinstance(token, str) and isinstance(ids, list):
                index[token] = {str(i) for i in ids}

        return index, last_built

    def parse_timestamp(value: str | None) -> datetime | None:
        if not value:
            return None
        try:
            normalized = value.strip()
            if normalized.endswith("Z"):
                normalized = normalized[:-1] + "+00:00"
            dt = datetime.fromisoformat(normalized)
            if dt.tzinfo is None:
                return dt.replace(tzinfo=UTC)
            return dt.astimezone(UTC)
        except ValueError:
            return None

    def update_inverted_index(
        inverted: dict[str, set[str]],
        records: list[dict[str, Any]],
    ) -> None:
        with Progress(
            SpinnerColumn(),
            TextColumn("[progress.description]{task.description}"),
            BarColumn(),
            TextColumn("{task.completed}/{task.total}"),
            console=console,
        ) as progress:
            task_id = progress.add_task(
                "Updating inverted index...",
                total=len(records),
            )

            for record in records:
                node_id = record.get("id")
                if not node_id:
                    progress.advance(task_id)
                    continue

                tokens: set[str] = set()
                tokens.update(utils.preprocess(record.get("title", "")))
                tokens.update(utils.preprocess(record.get("description", "")))
                tokens.update(utils.preprocess(record.get("category", "")))
                for tag in record.get("tags", []) or []:
                    tokens.update(utils.preprocess(str(tag)))

                for token in tokens:
                    inverted.setdefault(token, set()).add(node_id)

                progress.advance(task_id)

    try:
        existing_index, last_built = load_existing_index()

        with Progress(
            SpinnerColumn(),
            TextColumn("[progress.description]{task.description}"),
            console=console,
        ) as progress:
            progress.add_task(description="Reading OSF nodes...", total=None)

            records: list[dict[str, Any]] = []
            skipped_unpublished = 0
            with jsonl.open(osf_nodes_file) as reader:
                for record in reader:
                    date_modified = parse_timestamp(record.get("date_modified"))
                    if last_built and date_modified and date_modified <= last_built:
                        skipped_unpublished += 1
                        continue
                    records.append(record)

        if not records:
            console.print("[yellow]No records to update.[/yellow]")
            return
        console.print(f"[cyan]Loaded {len(records)} nodes from {osf_nodes_file}[/cyan]")

        update_inverted_index(existing_index, records)
        now_iso = datetime.now(tz=UTC).isoformat()

        _INDEX_PATH.parent.mkdir(parents=True, exist_ok=True)
        with _INDEX_PATH.open("w", encoding="utf-8") as f:
            json.dump(
                {
                    "last_built": now_iso,
                    "index": {
                        token: sorted(ids)
                        for token, ids in sorted(existing_index.items())
                    },
                },
                f,
                ensure_ascii=True,
            )

        console.print("\n[bold green]Inverted index updated successfully![/bold green]")
        console.print(f"[cyan]New nodes indexed: {len(records)}[/cyan]")
        console.print(f"[cyan]Skipped (not newer): {skipped_unpublished}[/cyan]")
        console.print(f"[cyan]Unique tokens: {len(existing_index)}[/cyan]")
        console.print(f"[cyan]Last built: {now_iso}[/cyan]")
        console.print(f"[cyan]Output: {_INDEX_PATH}[/cyan]")

    except Exception as e:
        console.print(f"[red]Error: {e}[/red]")
        raise typer.Exit(1) from e


@osf_app.command("download")
def osf_download(
    ctx: typer.Context,
    project_id: str = typer.Argument(..., help="OSF project ID"),
    output: Path = typer.Option(
        Path("./osf_datasets"),
        "--output",
        "-o",
        help="Output directory",
    ),
    provider: str = typer.Option(
        "osfstorage",
        "--provider",
        "-p",
        help="Storage provider",
    ),
    recursive: bool = typer.Option(
        False,
        "-r",
        "--recursive",
        help="Recursively traverse all folders for files.",
    ),
    override: bool = typer.Option(
        False,
        "--force",
        "-f",
        help="Force overriding existing files (use with caution)",
    ),
) -> None:
    """Download all files from an OSF project.

    Examples:
        osf_tool.py download abc12
        osf_tool.py download abc12 --output ./my_project
        osf_tool.py download abc12 -r

    """
    IV.enable(project_id)

    client: OSFClient = ctx.obj["client"]

    try:
        with Progress(
            SpinnerColumn(),
            TextColumn("[progress.description]{task.description}"),
            console=console,
        ) as progress:
            # Create output directory for this project
            project_dir = output / project_id
            project_dir.mkdir(parents=True, exist_ok=True)

            mode_str = "recursively" if recursive else "(non-recursively)"
            description_str = (
                f"[cyan]Downloading files {mode_str} from project "
                f"{project_id} to {project_dir}[/cyan]\n"
            )
            progress.add_task(description=description_str, total=None)

            count, skipped = client.download_all_files(
                project_id,
                project_dir,
                provider,
                recursive,
                override,
            )

            IV.enable(project_id)
            count, skipped = IV.copy_files(project_dir, override, count, skipped)

            console.print(
                f"\n[bold green]Downloaded {count} files successfully![/bold green]",
            )
            if skipped > 0:
                console.print(f"[yellow]Skipped {skipped} existing files.[/yellow]")

    except Exception as e:
        console.print(f"[red]Error: {e}[/red]")
        raise typer.Exit(1) from e


@osf_app.callback()
def osf_main(ctx: typer.Context) -> None:
    """OSF Tool - Search and download projects from the Open Science Framework."""
    token = os.getenv("OSF_TOKEN")
    if not token:
        console.print(
            "[red]Error: No OSF token provided. "
            "Set OSF_TOKEN environment variable for authenticated requests.[/red]",
        )
        raise typer.Exit(1)
    ctx.obj = {
        "client": OSFClient(token=token),
    }
