"""OpenML Tool - Search and download datasets from OpenML."""

from __future__ import annotations

import os
from pathlib import Path

import openml
import typer
from rich.progress import Progress, SpinnerColumn, TextColumn

from datasets.utils import console

openml_app = typer.Typer(help="OpenML Tool - Search and download datasets from OpenML.")


@openml_app.callback()
def openml_main() -> None:
    """OpenML Tool - Search and download datasets from OpenML."""
    try:
        _ = openml.datasets  # Ensure the package works
    except ImportError:
        console.print(
            "[red]Error: openml library is not installed. "
            "Install with 'pip install openml' "
            "to use OpenML features.[/red]",
        )
        raise typer.Exit(1) from None

    # Set up OpenML API key if available
    api_key = os.getenv("OPENML_API_KEY")
    if api_key:
        openml.config.apikey = api_key


@openml_app.command("search")
def openml_search(
    search_term: str | None = typer.Argument(
        None,
        help="Search term (shortcut for --query)",
    ),
    query: str | None = typer.Option(
        None,
        "--query",
        "-q",
        help="Search query for dataset names",
    ),
    tag: str | None = typer.Option(
        None,
        "--tag",
        "-t",
        help="Filter by tag",
    ),
    number_instances: str | None = typer.Option(
        None,
        "--instances",
        "-i",
        help="Filter by number of instances (format: 'min..max' or 'exact')",
    ),
    number_features: str | None = typer.Option(
        None,
        "--features",
        "-f",
        help="Filter by number of features (format: 'min..max' or 'exact')",
    ),
    status: str = typer.Option(
        "active",
        "--status",
        "-s",
        help="Filter by dataset status (active, deactivated, in_preparation)",
    ),
    limit: int = typer.Option(
        15,
        "--limit",
        help="Maximum number of results to return",
    ),
) -> None:
    """Search for datasets on OpenML.

    Examples:
        openml search --query "iris"
        openml search --tag "study_1"
        openml search --instances "100..1000" --features "5..20"
        openml search --query "mnist" --limit 5

    """
    # Positional search_term acts as --query shortcut
    if search_term is not None and query is None:
        query = search_term

    try:
        with Progress(
            SpinnerColumn(),
            TextColumn("[progress.description]{task.description}"),
            console=console,
        ) as progress:
            progress.add_task(description="Searching OpenML...", total=None)

            # Build filter parameters
            filters = {}
            if query:
                filters["data_name"] = query
            if tag:
                filters["tag"] = tag
            if status:
                filters["status"] = status

            # Parse number ranges
            if number_instances:
                if ".." in number_instances:
                    min_val, max_val = number_instances.split("..")
                    filters["number_instances"] = f"{min_val}..{max_val}"
                else:
                    filters["number_instances"] = number_instances

            if number_features:
                if ".." in number_features:
                    min_val, max_val = number_features.split("..")
                    filters["number_features"] = f"{min_val}..{max_val}"
                else:
                    filters["number_features"] = number_features

            # Search datasets
            datasets = openml.datasets.list_datasets(
                output_format="dataframe",
                size=limit,
                **filters,
            )

        if datasets is None or datasets.empty:
            console.print("[yellow]No datasets found.[/yellow]")
            return

        # Limit results
        datasets = datasets.head(limit)

        console.print(f"\n[bold green]Found {len(datasets)} datasets[/bold green]\n")

        header = ["ID", "Name", "Version", "Instances", "Features", "Status"]
        console.print("\t".join(header))

        for idx, row in datasets.iterrows():
            dataset_id = str(idx)
            name = str(row.get("name", "-"))[:40]  # Truncate long names
            version = str(row.get("version", "-"))
            instances = str(row.get("NumberOfInstances", "-")).split(".")[0]
            features = str(row.get("NumberOfFeatures", "-")).split(".")[0]
            dataset_status = str(row.get("status", "-"))

            result_row = [
                dataset_id,
                name,
                version,
                instances,
                features,
                dataset_status,
            ]
            console.print("\t".join(result_row))

    except Exception as e:
        console.print(f"[red]Error: {e}[/red]")
        raise typer.Exit(1) from e


@openml_app.command("info")
def openml_info(
    dataset_id: int = typer.Argument(
        ...,
        help="Dataset ID (e.g., 61 for 'iris')",
    ),
) -> None:
    """Display detailed information about an OpenML dataset.

    Examples:
        openml info 61
        openml info 554
        openml info 40996

    """
    try:
        with Progress(
            SpinnerColumn(),
            TextColumn("[progress.description]{task.description}"),
            console=console,
        ) as progress:
            progress.add_task(
                description=f"Fetching dataset {dataset_id}...",
                total=None,
            )

            # Fetch dataset information
            dataset = openml.datasets.get_dataset(dataset_id, download_data=False)

        # Display header
        console.print(f"\n[bold cyan]Dataset: {dataset.name}[/bold cyan]\n")

        # Display basic information
        desc_max_len = 500
        desc_text = "-"
        if dataset.description:
            if len(dataset.description) > desc_max_len:
                desc_text = dataset.description[:desc_max_len] + "..."
            else:
                desc_text = dataset.description

        info_items = [
            ("ID", dataset.dataset_id),
            ("Name", dataset.name),
            ("Version", dataset.version),
            ("Description", desc_text),
            ("Format", dataset.format or "-"),
            ("Upload Date", dataset.upload_date or "-"),
            ("Licence", dataset.licence or "-"),
            (
                "Instances",
                dataset.qualities.get("NumberOfInstances", "-")
                if dataset.qualities
                else "-",
            ),
            (
                "Features",
                dataset.qualities.get("NumberOfFeatures", "-")
                if dataset.qualities
                else "-",
            ),
            (
                "Missing Values",
                dataset.qualities.get("NumberOfMissingValues", "-")
                if dataset.qualities
                else "-",
            ),
            ("Default Target", dataset.default_target_attribute or "-"),
        ]

        desc_display_threshold = 80
        for label, value in info_items:
            if (
                label == "Description"
                and value != "-"
                and len(str(value)) > desc_display_threshold
            ):
                console.print(f"[bold]{label}:[/bold]\n  {value}")
            else:
                console.print(f"[bold]{label}:[/bold] {value}")

        # Display tags if available
        if dataset.tag:
            tags_str = ", ".join(dataset.tag)
            console.print(f"\n[bold]Tags:[/bold] {tags_str}")

        # Display URL
        console.print(f"\n[bold]URL:[/bold] https://www.openml.org/d/{dataset_id}")

        console.print()

    except Exception as e:
        console.print(f"[red]Error: {e}[/red]")
        raise typer.Exit(1) from e


@openml_app.command("download")
def openml_download(
    dataset_id: int = typer.Argument(
        ...,
        help="Dataset ID (e.g., 61 for 'iris')",
    ),
    output: Path = typer.Option(
        Path("./openml_datasets"),
        "--output",
        "-o",
        help="Output directory",
    ),
) -> None:
    """Download a dataset from OpenML.

    Examples:
        openml download 61
        openml download 554 --output ./datasets
        openml download 40996 --output ./my_data

    """
    try:
        # Create output directory
        output.mkdir(parents=True, exist_ok=True)

        console.print(
            f"[cyan]Downloading dataset {dataset_id} to {output}[/cyan]\n",
        )

        with Progress(
            SpinnerColumn(),
            TextColumn("[progress.description]{task.description}"),
            console=console,
        ) as progress:
            progress.add_task(
                description=f"Downloading dataset {dataset_id}...",
                total=None,
            )

            # Download the dataset
            dataset = openml.datasets.get_dataset(dataset_id, download_data=True)
            data_x, data_y, _, _ = dataset.get_data(
                dataset_format="dataframe",
                target=dataset.default_target_attribute,
            )

        # Save to files
        dataset_name = dataset.name.replace(" ", "_")
        dataset_dir = output / f"dataset_{dataset_id}_{dataset_name}"
        dataset_dir.mkdir(parents=True, exist_ok=True)

        # Save data
        if data_x is not None:
            data_path = dataset_dir / "data.csv"
            if data_y is not None:
                # Combine features and target
                data_x["target"] = data_y
            data_x.to_csv(data_path, index=False)
            console.print(f"[green]✓[/green] Data saved to: {data_path}")

        # Save metadata
        metadata_path = dataset_dir / "metadata.txt"
        with metadata_path.open("w") as f:
            f.write(f"Dataset ID: {dataset.dataset_id}\n")
            f.write(f"Name: {dataset.name}\n")
            f.write(f"Version: {dataset.version}\n")
            f.write(f"Description: {dataset.description}\n")
            f.write(f"Format: {dataset.format}\n")
            f.write(f"Upload Date: {dataset.upload_date}\n")
            f.write(f"Licence: {dataset.licence}\n")
            f.write(f"Default Target: {dataset.default_target_attribute}\n")
            if dataset.qualities:
                num_instances = dataset.qualities.get(
                    "NumberOfInstances",
                    "N/A",
                )
                num_features = dataset.qualities.get("NumberOfFeatures", "N/A")
                f.write(f"Instances: {num_instances}\n")
                f.write(f"Features: {num_features}\n")
            f.write(f"URL: https://www.openml.org/d/{dataset_id}\n")
        console.print(f"[green]✓[/green] Metadata saved to: {metadata_path}")

        console.print(
            "\n[bold green]Dataset downloaded successfully![/bold green]",
        )
        console.print(f"[cyan]Location: {dataset_dir}[/cyan]")

    except Exception as e:
        console.print(f"[red]Error: {e}[/red]")
        raise typer.Exit(1) from e
