"""Data Exploration Tools - Search and Download from OSF, Hugging Face, and Kaggle.

A lightweight package to search for projects on OSF, filter by various metadata,
and download all associated files.
"""

import os

import typer

from datasets._github import github_app
from datasets._hf import hf_app
from datasets._kaggle import kaggle_app
from datasets._openml import openml_app
from datasets._osf import osf_app
from datasets.utils import console

app = typer.Typer()
app.add_typer(osf_app, name="osf", invoke_without_command=True)
app.add_typer(github_app, name="github", invoke_without_command=True)
app.add_typer(hf_app, name="hf", invoke_without_command=True)
app.add_typer(kaggle_app, name="kaggle", invoke_without_command=True)
app.add_typer(openml_app, name="openml", invoke_without_command=True, hidden=True)


def main() -> None:
    """Entry point for the datasets CLI."""
    # Check API availabilities and print warnings if necessary
    if not os.getenv("GITHUB_TOKEN"):
        console.print(
            "[bold yellow]Warning: GitHub API token not found. "
            "Set the GITHUB_TOKEN environment variable to use "
            "GitHub features with higher rate limits.[/bold yellow]",
        )
    if not os.getenv("HF_TOKEN"):
        console.print(
            "[bold yellow]Warning: Hugging Face API token not found. "
            "Set the HF_TOKEN environment variable to use "
            "Hugging Face features.[/bold yellow]",
        )
    if not os.getenv("KAGGLE_API_TOKEN"):
        console.print(
            "[bold yellow]Warning: Kaggle API credentials not found. "
            "Set KAGGLE_API_TOKEN environment variables to use Kaggle.[/bold yellow]",
        )
    if not os.getenv("OSF_TOKEN"):
        console.print(
            "[bold yellow]Warning: OSF API token not found. "
            "Set the OSF_TOKEN environment variable to use OSF features.[/bold yellow]",
        )

    app()


if __name__ == "__main__":
    main()
