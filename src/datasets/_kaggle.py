"""Kaggle Tool - Search and download datasets from Kaggle."""

from __future__ import annotations

import json
import tempfile
from pathlib import Path

import typer
from kaggle import KaggleApi
from rich.markup import escape
from rich.progress import Progress, SpinnerColumn, TextColumn

from datasets import utils
from datasets.utils import console

kaggle_app = typer.Typer(help="Kaggle Tool - Search and download datasets from Kaggle.")


@kaggle_app.callback()
def kaggle_main(ctx: typer.Context) -> None:
    """Kaggle Tool - Search and download datasets from Kaggle."""
    if not KaggleApi:
        console.print(
            "[red]Error: kaggle library is not installed. "
            "Install with 'uv add kaggle' to use Kaggle features.[/red]",
        )
        raise typer.Exit(1)

    # Initialize and authenticate Kaggle API
    api = KaggleApi()
    try:
        api.authenticate()
    except Exception as e:
        console.print(
            f"[red]Error: Failed to authenticate with Kaggle API: {e}[/red]\n"
            "[yellow]Make sure you have a valid kaggle.json file in ~/.kaggle/ "
            "or set KAGGLE_USERNAME and KAGGLE_KEY environment variables.[/yellow]",
        )
        raise typer.Exit(1) from e

    ctx.obj = {
        "client": api,
    }


@kaggle_app.command("search")
def kaggle_search(
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
    sort_by: str = typer.Option(
        "hottest",
        "--sort-by",
        "-s",
        help="Sort by: hottest, votes, updated, active, published",
    ),
    tags: str | None = typer.Option(
        None,
        "--tags",
        help="Filter by tags (comma-separated)",
    ),
    limit: int = typer.Option(
        25,
        "--limit",
        help="Maximum number of results to return",
    ),
) -> None:
    """Search for datasets on Kaggle.

    Examples:
        kaggle search --query "covid-19"
        kaggle search --query "covid" --sort-by votes
        kaggle search --file-type csv --limit 20
        kaggle search --tags "healthcare,medicine"
        kaggle search --license cc

    """
    # Positional search_term acts as --query shortcut
    if search_term is not None and query is None:
        query = search_term

    client: KaggleApi = ctx.obj["client"]

    try:
        with Progress(
            SpinnerColumn(),
            TextColumn("[progress.description]{task.description}"),
            console=console,
        ) as progress:
            progress.add_task(description="Searching Kaggle...", total=None)

            # Search datasets
            datasets = []
            for mine in [False, True]:
                datasets.extend(
                    client.dataset_list(
                        search=query or "",
                        sort_by=sort_by,
                        file_type="all",
                        license_name="all",
                        tag_ids=tags or "",
                        mine=mine,
                        page=1,
                    )
                )

            # Reapply sorting after combining mine and non-mine datasets
            if sort_by == "hottest":
                datasets.sort(
                    key=lambda d: getattr(d, "download_count", 0), reverse=True,
                )
            elif sort_by == "votes":
                datasets.sort(key=lambda d: getattr(d, "vote_count", 0), reverse=True)
            elif sort_by in ["updated", "active"]:
                datasets.sort(
                    key=lambda d: getattr(d, "last_updated", None), reverse=True,
                )
            elif sort_by == "published":
                datasets.sort(key=lambda d: getattr(d, "last_updated", None))

        if not datasets:
            console.print("[yellow]No datasets found.[/yellow]")
            return

        console.print(f"\n[bold green]Found {len(datasets)} datasets[/bold green]\n")

        header = [
            "Owner/Dataset",
            "Size",
            "Last Updated",
            "Downloads",
            "Votes",
            "Title",
        ]
        console.print("\t".join(header))

        for i, dataset in enumerate(datasets):
            if i >= limit:
                break
            dataset_ref = f"{dataset.ref}"
            split_len = 50
            title = escape(
                dataset.title[:50] + "..."
                if len(dataset.title) > split_len
                else dataset.title,
            )
            size = dataset.total_bytes if hasattr(dataset, "total_bytes") else "N/A"
            size_str = utils.format_file_size(size)

            last_updated = (
                str(dataset.last_updated)[:10]
                if hasattr(dataset, "last_updated") and dataset.last_updated
                else "N/A"
            )
            downloads = (
                str(dataset.download_count)
                if hasattr(dataset, "download_count")
                else "0"
            )
            votes = str(dataset.vote_count) if hasattr(dataset, "vote_count") else "0"

            row = [
                dataset_ref,
                size_str,
                last_updated,
                downloads,
                votes,
                title,
            ]
            console.print("\t".join(row))

    except Exception as e:
        console.print(f"[red]Error: {e}[/red]")
        raise typer.Exit(1) from e


@kaggle_app.command("download")
def kaggle_download(
    ctx: typer.Context,
    dataset: str = typer.Argument(
        ...,
        help="Dataset identifier (e.g., 'owner/dataset-name')",
    ),
    output: Path = typer.Option(
        Path("./kaggle_datasets"),
        "--output",
        "-o",
        help="Output directory",
    ),
    unzip: bool = typer.Option(
        True,
        "--unzip/--no-unzip",
        help="Unzip downloaded files",
    ),
    force: bool = typer.Option(
        False,
        "--force",
        "-f",
        help="Force download even if files already exist",
    ),
) -> None:
    """Download a dataset from Kaggle.

    Examples:
        kaggle download owid/covid-19-data
        kaggle download owid/covid-19-data --output ./data
        kaggle download owner/dataset --no-unzip
        kaggle download owner/dataset --force

    """
    client: KaggleApi = ctx.obj["client"]

    # Validate dataset format
    if "/" not in dataset:
        console.print(
            "[red]Error: Dataset identifier should "
            "be in format 'owner/dataset-name'[/red]",
        )
        raise typer.Exit(1)

    try:
        # Create output directory
        output.mkdir(parents=True, exist_ok=True)

        console.print(
            f"[cyan]Downloading dataset '{dataset}' to {output}[/cyan]\n",
        )

        with Progress(
            SpinnerColumn(),
            TextColumn("[progress.description]{task.description}"),
            console=console,
        ) as progress:
            progress.add_task(
                description=f"Downloading {dataset}...",
                total=None,
            )

            # Download the dataset
            client.dataset_download_files(
                dataset=dataset,
                path=str(output),
                unzip=unzip,
                force=force,
                quiet=False,
            )

        console.print(
            "\n[bold green]Dataset downloaded successfully![/bold green]",
        )
        console.print(f"[cyan]Location: {output.absolute()}[/cyan]")

    except Exception as e:
        console.print(f"[red]Error: {e}[/red]")
        raise typer.Exit(1) from e


@kaggle_app.command("info")
def kaggle_info(
    ctx: typer.Context,
    dataset: str = typer.Argument(
        ...,
        help="Dataset identifier (e.g., 'owner/dataset-name')",
    ),
) -> None:
    """Display detailed information about a Kaggle dataset.

    Examples:
        kaggle info owid/covid-19-data
        kaggle info zillow/zecon
        kaggle info owner/dataset-name

    """
    client: KaggleApi = ctx.obj["client"]

    if "/" not in dataset:
        console.print(
            "[red]Error: Dataset identifier should "
            "be in format 'owner/dataset-name'[/red]",
        )
        raise typer.Exit(1)

    try:
        with Progress(
            SpinnerColumn(),
            TextColumn("[progress.description]{task.description}"),
            console=console,
        ) as progress:
            progress.add_task(
                description=f"Fetching dataset info for {dataset}...",
                total=None,
            )
            user, title = dataset.split("/")
            dataset_info = client.dataset_list(user=user, search=title)

        if not dataset_info:
            console.print("[yellow]Dataset not found.[/yellow]")
            return
        dataset_info = dataset_info[0]

        dataset_ref = getattr(dataset_info, "ref", dataset)
        owner_name = getattr(dataset_info, "creator_name", "-")
        title = getattr(dataset_info, "title", "-")
        subtitle = getattr(dataset_info, "subtitle", "-")

        description = getattr(dataset_info, "description", "-")
        if not description:
            try:
                with tempfile.TemporaryDirectory() as temp_dir:
                    path = client.dataset_metadata(dataset=dataset, path=temp_dir)
                    with Path(path).open() as f:
                        description = json.load(f)["info"]["description"]
            except:
                description = ""
        size = utils.format_file_size(getattr(dataset_info, "total_bytes", None))
        downloads = getattr(dataset_info, "download_count", 0)
        votes = getattr(dataset_info, "vote_count", 0)
        usability = getattr(dataset_info, "usability_rating", "-")
        license_name = getattr(dataset_info, "license_name", "-")
        last_updated = getattr(dataset_info, "last_updated", None)
        tags = [tag.name for tag in getattr(dataset_info, "tags", [])]

        console.print(f"\n[bold cyan]Dataset: {dataset_ref}[/bold cyan]\n")

        info_items = [
            ("Title", title),
            ("Owner", owner_name),
            ("Subtitle", subtitle),
            ("Size", size),
            ("Downloads", downloads),
            ("Votes", votes),
            ("Usability", usability),
            ("License", license_name),
            ("Last Updated", str(last_updated)[:10] if last_updated else "-"),
        ]

        for label, value in info_items:
            console.print(f"[bold]{label}:[/bold] {value}")

        if tags:
            console.print(f"[bold]Tags:[/bold] {', '.join(tags)}")

        if description and description != "-":
            console.print(f"[bold]Description:[/bold]\n{description}")

        console.print(
            f"[bold]URL:[/bold] https://www.kaggle.com/datasets/{dataset_ref}",
        )
        console.print()

    except Exception as e:
        console.print(f"[red]Error: {e}[/red]")
        raise typer.Exit(1) from e
