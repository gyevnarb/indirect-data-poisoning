"""GitHub Tool - Search and download dataset repositories from GitHub."""

from __future__ import annotations

import os
import shutil
from pathlib import Path
from typing import Any

import typer
from rich.markup import escape
from rich.progress import Progress, SpinnerColumn, TextColumn

from datasets import utils
from datasets.utils import BM25Scorer, console

try:
    from git import GitCommandError, Repo
except ImportError:  # pragma: no cover - dependency check
    GitCommandError = None
    Repo = None

try:
    from github import Auth, Github, GithubException, UnknownObjectException
except ImportError:  # pragma: no cover - dependency check
    Auth = None
    Github = None
    GithubException = Exception
    UnknownObjectException = Exception


github_app = typer.Typer(
    help="GitHub Tool - Search and download dataset repositories from GitHub.",
)
DEFAULT_GITHUB_DATASET_QUERY = "dataset in:name,description,readme"
MAX_SEARCH_DESCRIPTION_LENGTH = 70


def _build_repo_query(
    query: str | None,
    owner: str | None,
    language: str | None,
) -> str:
    """Build a GitHub repository search query."""
    terms = [
        f"{query} in:name,description,readme"
        if query
        else DEFAULT_GITHUB_DATASET_QUERY,
    ]

    if owner:
        terms.append(f"user:{owner}")
    if language:
        terms.append(f"language:{language}")

    return " ".join(terms)


@github_app.callback()
def github_main(ctx: typer.Context) -> None:
    """GitHub Tool - Search and download repositories from GitHub."""
    if not Github or not Repo:
        console.print(
            "[red]Error: GitPython and PyGithub are required. "
            "Install with 'uv add gitpython pygithub' to use GitHub features.[/red]",
        )
        raise typer.Exit(1)

    token = os.getenv("GITHUB_TOKEN")
    auth = Auth.Token(token) if token and Auth else None
    ctx.obj = {
        "client": Github(auth=auth) if auth else Github(),
    }


@github_app.command("search")
def github_search(  # noqa: PLR0913
    ctx: typer.Context,
    search_term: str | None = typer.Argument(
        None,
        help="Search term (shortcut for --query)",
    ),
    query: str | None = typer.Option(
        None,
        "--query",
        "-q",
        help="Search query for repository names, descriptions, and READMEs.",
    ),
    owner: str | None = typer.Option(
        None,
        "--owner",
        "-o",
        help="Filter by repository owner or organization",
    ),
    language: str | None = typer.Option(
        None,
        "--language",
        "-l",
        help="Filter by repository (programming) language",
    ),
    sort: str = typer.Option(
        "relevance",
        "--sort",
        "-s",
        help="Sort by: stars, forks, updated, relevance",
    ),
    limit: int = typer.Option(
        25,
        "--limit",
        help="Maximum number of results to return",
    ),
) -> None:
    """Search for dataset repositories on GitHub.

    Note:
        GitHub is not a dedicated dataset platform, so search results may include
        repositories that are not datasets. Use specific queries and filters to find
        relevant repositories. For example, include "dataset" in your query and filter by
        language or owner to narrow down results.


    Examples:
        github search --query "medical imaging"
        github search --language python
        github search --owner huggingface --sort updated
        github search --query genomics --limit 20

    """
    # Positional search_term acts as --query shortcut
    if search_term is not None and query is None:
        query = search_term

    client: Any = ctx.obj["client"]
    search_query = _build_repo_query(query, owner, language)

    # For relevance sorting we re-rank client-side with BM25, so we need to
    # fetch a larger candidate pool first using GitHub's default relevance order.
    use_relevance = sort.lower() == "relevance"
    if use_relevance and not query:
        console.print(
            "[yellow]Warning: Relevance sorting requires a --query. "
            "Falling back to stars sort.[/yellow]",
        )
        use_relevance = False

    github_sort = "" if use_relevance else sort
    fetch_limit = limit * 3 if use_relevance else limit

    try:
        with Progress(
            SpinnerColumn(),
            TextColumn("[progress.description]{task.description}"),
            console=console,
        ) as progress:
            progress.add_task(
                description="Searching GitHub repositories...",
                total=None,
            )
            search_kwargs: dict[str, Any] = {"query": search_query, "order": "desc"}
            if github_sort:
                search_kwargs["sort"] = github_sort
            search_results = client.search_repositories(**search_kwargs)

            repositories = []
            for index, repository in enumerate(search_results):
                if index >= fetch_limit:
                    break
                repositories.append(repository)

        if use_relevance and repositories:
            scorer = BM25Scorer()
            documents = [
                " ".join(
                    [
                        repo.name or "",
                        repo.name or "",  # weight name more heavily
                        repo.description or "",
                        " ".join(repo.get_topics()),
                    ]
                )
                for repo in repositories
            ]
            scores = scorer.score(query, documents)
            repositories = [
                repo
                for repo, _ in sorted(
                    zip(repositories, scores, strict=True),
                    key=lambda pair: pair[1],
                    reverse=True,
                )
            ][:limit]

        if not repositories:
            console.print("[yellow]No repositories found.[/yellow]")
            return

        console.print(
            f"\n[bold green]Found {len(repositories)} repositories[/bold green]\n",
        )

        header = [
            "Repository",
            "Stars",
            "Forks",
            "Language",
            "Updated",
            "Description",
        ]
        console.print("\t".join(header))

        for repository in repositories:
            description = repository.description or "-"
            if len(description) > MAX_SEARCH_DESCRIPTION_LENGTH:
                description = description[: MAX_SEARCH_DESCRIPTION_LENGTH - 3] + "..."

            row = [
                repository.full_name,
                str(repository.stargazers_count),
                str(repository.forks_count),
                repository.language or "-",
                str(repository.updated_at)[:10] if repository.updated_at else "-",
                escape(description),
            ]
            console.print("\t".join(row))

    except GithubException as e:
        console.print(f"[red]Error: {e}[/red]")
        raise typer.Exit(1) from e


@github_app.command("info")
def github_info(
    ctx: typer.Context,
    repository: str = typer.Argument(
        ...,
        help="Repository identifier (e.g., 'owner/repository-name')",
    ),
) -> None:
    """Display detailed information about a GitHub repository.

    Examples:
        github info huggingface/datasets
        github info scikit-learn/scikit-learn
        github info owner/dataset-repo

    """
    client: Any = ctx.obj["client"]

    if "/" not in repository:
        console.print(
            "[red]Error: Repository identifier should be in format "
            "'owner/repository-name'[/red]",
        )
        raise typer.Exit(1)

    try:
        with Progress(
            SpinnerColumn(),
            TextColumn("[progress.description]{task.description}"),
            console=console,
        ) as progress:
            progress.add_task(
                description=f"Fetching repository info for {repository}...",
                total=None,
            )
            repo = client.get_repo(repository)

        console.print(f"\n[bold cyan]Repository: {repo.full_name}[/bold cyan]\n")

        topics = repo.get_topics()
        license_name = repo.license.name if repo.license else "-"
        info_items = [
            ("Name", repo.name),
            ("Owner", repo.owner.login),
            ("Description", repo.description or "-"),
            ("Language", repo.language or "-"),
            ("Size", utils.format_file_size(repo.size * 1024)),
            ("Stars", repo.stargazers_count),
            ("Watchers", repo.watchers_count),
            ("Forks", repo.forks_count),
            ("Open Issues", repo.open_issues_count),
            ("Default Branch", repo.default_branch),
            ("License", license_name),
            ("Archived", "Yes" if repo.archived else "No"),
            ("Created", str(repo.created_at)[:10] if repo.created_at else "-"),
            ("Updated", str(repo.updated_at)[:10] if repo.updated_at else "-"),
            ("Pushed", str(repo.pushed_at)[:10] if repo.pushed_at else "-"),
            ("Homepage", repo.homepage or "-"),
            ("URL", repo.html_url),
            ("Clone URL", repo.clone_url),
        ]

        for label, value in info_items:
            console.print(f"[bold]{label}:[/bold] {value}")

        if topics:
            console.print(f"[bold]Topics:[/bold] {', '.join(topics)}")

        console.print()

    except UnknownObjectException as e:
        console.print(f"[red]Error: Repository '{repository}' was not found.[/red]")
        raise typer.Exit(1) from e
    except GithubException as e:
        console.print(f"[red]Error: {e}[/red]")
        raise typer.Exit(1) from e


@github_app.command("download")
def github_download(  # noqa: PLR0913
    ctx: typer.Context,
    repository: str = typer.Argument(
        ...,
        help="Repository identifier (e.g., 'owner/repository-name')",
    ),
    output: Path = typer.Option(
        Path("./github_datasets"),
        "--output",
        "-o",
        help="Output directory",
    ),
    branch: str | None = typer.Option(
        None,
        "--branch",
        "-b",
        help="Optional branch to clone",
    ),
    depth: int = typer.Option(
        1,
        "--depth",
        help="Clone depth (use 0 for a full clone)",
    ),
    force: bool = typer.Option(
        False,
        "--force",
        "-f",
        help="Overwrite an existing cloned repository",
    ),
) -> None:
    """Easily download a dataset repository from GitHub.

    Examples:
        github download huggingface/datasets
        github download owner/dataset-repo --output ./data
        github download owner/dataset-repo --branch main --depth 1
        github download owner/dataset-repo --force

    """
    client: Any = ctx.obj["client"]

    if "/" not in repository:
        console.print(
            "[red]Error: Repository identifier should be in format "
            "'owner/repository-name'[/red]",
        )
        raise typer.Exit(1)

    try:
        repo = client.get_repo(repository)
        output.mkdir(parents=True, exist_ok=True)
        destination = output / repository.replace("/", "_")

        if destination.exists():
            if not force:
                console.print(
                    "[red]Error: Destination "
                    f"{destination} already exists. Use --force to overwrite.[/red]",
                )
                raise typer.Exit(1)
            shutil.rmtree(destination)

        clone_kwargs: dict[str, object] = {}
        if branch:
            clone_kwargs["branch"] = branch
            clone_kwargs["single_branch"] = True
        if depth > 0:
            clone_kwargs["depth"] = depth

        console.print(
            f"[cyan]Downloading repository '{repository}' to {destination}[/cyan]\n",
        )

        token = os.getenv("GITHUB_TOKEN")
        clone_url = repo.clone_url
        if token:
            clone_url = clone_url.replace("https://", f"https://{token}@")

        Repo.clone_from(clone_url, destination, **clone_kwargs)

        console.print("\n[bold green]Repository downloaded successfully![/bold green]")
        console.print(f"[cyan]Location: {destination}[/cyan]")

    except UnknownObjectException as e:
        console.print(f"[red]Error: Repository '{repository}' was not found.[/red]")
        raise typer.Exit(1) from e
    except GitCommandError as e:
        console.print(f"[red]Error: {e}[/red]")
        raise typer.Exit(1) from e
    except GithubException as e:
        console.print(f"[red]Error: {e}[/red]")
        raise typer.Exit(1) from e
