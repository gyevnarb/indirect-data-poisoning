"""Hugging Face Tool - Search and download datasets from Hugging Face."""

from __future__ import annotations

import os
import re
from pathlib import Path

import typer
from huggingface_hub import HfApi
from rich.progress import Progress, SpinnerColumn, TextColumn

from datasets.utils import console

hf_app = typer.Typer(help="HF Tool - Search and download datasets from Hugging Face.")


@hf_app.callback()
def hf_main(ctx: typer.Context) -> None:
    """HF Tool - Search and download datasets from Hugging Face."""
    if not HfApi:
        console.print(
            "[red]Error: huggingface_hub library is not installed. "
            "Install with 'pip install huggingface_hub' "
            "to use Hugging Face features.[/red]",
        )
        raise typer.Exit(1)

    token = os.getenv("HF_TOKEN")
    ctx.obj = {
        "client": HfApi(token=token) if token else HfApi(),
    }


@hf_app.command("search")
def hf_search(
    ctx: typer.Context,
    search_term: str | None = typer.Argument(
        None,
        help="Search term (shortcut for --query)",
    ),
    query: str | None = typer.Option(
        None,
        "--query",
        "-q",
        help="Search query for dataset names and descriptions",
    ),
    author: str | None = typer.Option(
        None,
        "--author",
        "-a",
        help="Filter by dataset author",
    ),
    tags: str | None = typer.Option(
        None,
        "--tags",
        help="Filter by tags (comma-separated)",
    ),
    language: str | None = typer.Option(
        None,
        "--language",
        "-l",
        help="Filter by dataset language",
    ),
    sort: str = typer.Option(
        "trending_score",
        "--sort",
        "-s",
        help="Sort by: trending_score, last_modified, created_at, downloads, likes",
    ),
    limit: int = typer.Option(
        25,
        "--limit",
        help="Maximum number of results to return",
    ),
) -> None:
    """Search for datasets on the Hugging Face Hub.

    Examples:
        hf search --query "imagenet"
        hf search --author "facebook" --sort downloads
        hf search --tags "image-classification,computer-vision"
        hf search --language "en" --license "mit"
        hf search --query "wikipedia" --sort downloads --limit 20

    """
    # Positional search_term acts as --query shortcut
    if search_term is not None and query is None:
        query = search_term

    client: HfApi = ctx.obj["client"]

    try:
        with Progress(
            SpinnerColumn(),
            TextColumn("[progress.description]{task.description}"),
            console=console,
        ) as progress:
            progress.add_task(description="Searching Hugging Face Hub...", total=None)

            # Build filter structure
            filters = {}
            if tags:
                tag_list = [t.strip() for t in tags.split(",")]
                filters["tags"] = tag_list
            if author:
                filters["author"] = author
            if language:
                filters["language"] = language

            # Split query into individual words; each must match independently.
            # The HF API's `search` only does a single substring match per
            # call, so we run one search per token and intersect the result
            # sets by dataset id.
            query_tokens = query.split() if query else []

            if len(query_tokens) <= 1:
                datasets = list(
                    client.list_datasets(
                        search=query,
                        filter=filters or None,
                        sort=sort,
                        full=True,
                        limit=limit,
                    ),
                )
            else:
                # Per-token cap: large enough that the overlap is meaningful,
                # but bounded so we don't paginate forever.
                per_token_limit = max(limit * 20, 500)

                # Fuzzy overlap: include any dataset that matches at least K
                # tokens, where K = min(num_tokens, 3).
                threshold = min(len(query_tokens), 3)

                hit_counts: dict[str, int] = {}
                seen: dict[str, object] = {}
                for token in query_tokens:
                    results = list(
                        client.list_datasets(
                            search=token,
                            filter=filters or None,
                            sort=sort,
                            full=True,
                            limit=per_token_limit,
                        ),
                    )
                    for d in results:
                        if d.id not in seen:
                            seen[d.id] = d
                    for dataset_id in {d.id for d in results}:
                        hit_counts[dataset_id] = hit_counts.get(dataset_id, 0) + 1

                # Sort by hit count (descending) so the most-overlapping
                # datasets surface first; ties keep insertion (sort) order.
                qualifying_ids = [
                    dataset_id
                    for dataset_id, count in hit_counts.items()
                    if count >= threshold
                ]
                qualifying_ids.sort(
                    key=lambda dataset_id: -hit_counts[dataset_id],
                )
                datasets = [seen[dataset_id] for dataset_id in qualifying_ids][:limit]

        if not datasets:
            console.print("[yellow]No datasets found.[/yellow]")
            return

        console.print(f"\n[bold green]Found {len(datasets)} datasets[/bold green]\n")

        header = ["ID", "Author", "Tags", "Downloads", "Likes", "Updated"]
        console.print("\t".join(header))

        for dataset in datasets:
            dataset_id = dataset.id
            author_name = dataset.author
            tags_str = ", ".join(dataset.tags) if dataset.tags else "-"
            downloads = getattr(dataset, "downloads", 0)
            likes = getattr(dataset, "likes", 0)
            updated = (
                str(dataset.lastModified)[:10]
                if hasattr(
                    dataset,
                    "lastModified",
                )
                else "-"
            )

            row = [
                dataset_id,
                author_name,
                tags_str,
                str(downloads),
                str(likes),
                updated,
            ]
            console.print("\t".join(row))

    except Exception as e:
        console.print(f"[red]Error: {e}[/red]")
        raise typer.Exit(1) from e


@hf_app.command("download")
def hf_download(
    ctx: typer.Context,
    dataset_id: str = typer.Argument(
        ...,
        help="Dataset ID (e.g., 'username/dataset-name')",
    ),
    output: Path = typer.Option(
        Path("./hf_datasets"),
        "--output",
        "-o",
        help="Output directory",
    ),
    repo_type: str = typer.Option(
        "dataset",
        "--repo-type",
        help="Repository type (usually 'dataset')",
    ),
) -> None:
    """Download a dataset from the Hugging Face Hub.

    Examples:
        hf download facebook/imagenet
        hf download facebook/imagenet --output ./datasets
        hf download mit/wikipedia --output ./wiki_data

    """
    client: HfApi = ctx.obj["client"]

    # Ensure dataset_id is properly formatted
    if "/" not in dataset_id:
        console.print(
            "[red]Error: Dataset ID should be in format 'author/dataset-name'[/red]",
        )
        raise typer.Exit(1)

    try:
        # Create output directory
        output.mkdir(parents=True, exist_ok=True)

        console.print(
            f"[cyan]Downloading dataset '{dataset_id}' to {output}[/cyan]\n",
        )

        with Progress(
            SpinnerColumn(),
            TextColumn("[progress.description]{task.description}"),
            console=console,
        ) as progress:
            progress.add_task(
                description=f"Downloading {dataset_id}...",
                total=None,
            )

            # Download the dataset
            local_dir = client.snapshot_download(
                repo_id=dataset_id,
                repo_type=repo_type,
                local_dir=output / dataset_id.replace("/", "_"),
                local_dir_use_symlinks=False,
            )

        console.print(
            "\n[bold green]Dataset downloaded successfully![/bold green]",
        )
        console.print(f"[cyan]Location: {local_dir}[/cyan]")

    except Exception as e:
        console.print(f"[red]Error: {e}[/red]")
        raise typer.Exit(1) from e


@hf_app.command("info")
def hf_info(
    ctx: typer.Context,
    dataset_id: str = typer.Argument(
        ...,
        help="Dataset ID (e.g., 'username/dataset-name')",
    ),
) -> None:
    """Display detailed information about a Hugging Face dataset.

    Examples:
        hf info facebook/imagenet
        hf info mit/wikipedia
        hf info huggingface/c4

    """
    client: HfApi = ctx.obj["client"]

    # Ensure dataset_id is properly formatted
    if "/" not in dataset_id:
        console.print(
            "[red]Error: Dataset ID should be in format 'author/dataset-name'[/red]",
        )
        raise typer.Exit(1)

    try:
        # Fetch dataset information
        dataset_info = client.dataset_info(repo_id=dataset_id)

        # Display header
        console.print(f"\n[bold cyan]Dataset: {dataset_id}[/bold cyan]\n")

        # Display basic information
        info_items = [
            ("ID", dataset_info.id),
            ("Author", dataset_info.author),
            (
                "Created",
                str(dataset_info.created_at)[:10] if dataset_info.created_at else "-",
            ),
            (
                "Last Modified",
                str(dataset_info.lastModified)[:10]
                if hasattr(dataset_info, "lastModified") and dataset_info.lastModified
                else "-",
            ),
            ("Downloads", getattr(dataset_info, "downloads", 0)),
            ("Likes", getattr(dataset_info, "likes", 0)),
        ]

        for label, value in info_items:
            console.print(f"[bold]{label}:[/bold] {value}")

        # Display description if available
        if dataset_info.description:
            description_text = re.sub(r'https?://[^\s<>"\']+', r"README.md", dataset_info.description)
            console.print(f"\n[bold]Description:[/bold]\n{description_text}")

        # Display tags if available
        if dataset_info.tags:
            tags_str = ", ".join(dataset_info.tags)
            console.print(f"\n[bold]Tags:[/bold] {tags_str}")

        # Display license if available
        if hasattr(dataset_info, "license") and dataset_info.license:
            console.print(f"[bold]License:[/bold] {dataset_info.license}")

        console.print()

    except Exception as e:
        console.print(f"[red]Error: {e}[/red]")
        raise typer.Exit(1) from e
