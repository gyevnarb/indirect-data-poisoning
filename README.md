# datasets — a multi-source dataset search & download wrapper

A lightweight Python CLI that searches for, inspects, and downloads datasets from
several open data platforms behind a single, uniform interface. It is the data
exploration tool used in the paper **"Distributed Denial of Science: How Indirect
Data Poisoning of AI Systems Can Industrialize Scientific Fraud."**

> **This is the source-only branch.** It contains just the `datasets` package and
> the files needed to install it. The full supplementary materials (poisoning data,
> experiment scripts, evaluation pipeline, analysis, and results) live on the
> [`main`](https://github.com/gyevnarb/indirect-data-poisoning/tree/main) branch.

## Supported providers

| Provider | CLI name | Auth env var |
|---|---|---|
| GitHub | `github` | `GITHUB_TOKEN` (optional; raises rate limits) |
| Open Science Framework (OSF) | `osf` | `OSF_TOKEN` |
| Hugging Face (HF) | `hf` | `HF_TOKEN` |
| Kaggle | `kaggle` | `KAGGLE_API_TOKEN` |
| OpenML | `openml` | none (search/download); see OpenML docs for uploads |

Each provider supports the same three subcommands: `search`, `info`, and
`download`. (OpenML is hidden from the CLI listing but still callable.)

## Requirements

- **Python 3.14+**

## Installation

This package is best installed with [uv](https://docs.astral.sh/uv/getting-started/installation/):

```bash
# From the repository root (an editable install exposing the `datasets` command).
uv tool install -e .
```

Alternatively, with pip:

```bash
pip install .
```

This installs a `datasets` command on your `PATH` (defined as the `datasets`
console script in `pyproject.toml`).

## Authentication

To use a given provider, set the matching environment variable so the CLI can make
authenticated requests. The tool prints a warning for any token it cannot find:

```bash
export GITHUB_TOKEN=...       # GitHub: authenticated requests & higher rate limits
export OSF_TOKEN=...          # Open Science Framework
export HF_TOKEN=...           # Hugging Face
export KAGGLE_API_TOKEN=...   # Kaggle (or use Kaggle's own credential file)
# OpenML needs no key for searching/downloading.
```

## Usage

The general form is:

```bash
datasets <provider> <command> [ARGS] [OPTIONS]
```

where `<provider>` is one of `osf`, `github`, `hf`, `kaggle`, `openml`, and
`<command>` is `search`, `info`, or `download`.

```bash
# Search a platform for matching datasets/projects.
datasets osf search "generative AI intrinsic motivation" --limit 25
datasets hf search "traffic accidents california"
datasets kaggle search "hiring discrimination"
datasets github search "fertility rate europe"

# Show metadata about a specific dataset/project/repo.
datasets osf info <node_id>

# Download all files for a dataset/project/repo.
datasets hf download <dataset_id>
```

Run any command with `--help` to see its full set of options:

```bash
datasets --help
datasets osf search --help
```

### OSF inverted index (optional, for fast OSF search)

Queries against the live OSF API can be very slow. The `osf` provider can instead
search a locally built inverted index over the OSF database. Two hidden commands
build and maintain it:

```bash
datasets osf fetch --help   # scrape OSF nodes into a local store
datasets osf index --help   # build/update the inverted index from the fetched nodes
```

Building the full index can take up to a day of continuous running; progress is
saved at intervals so the process can be stopped, resumed, and updated. Once built,
point the `osf search` command at the resulting index file (see `datasets osf
search --help`).

## Citation

If you rely on this tool in your project, please cite the paper:

```bibtex
@misc{gyevnar2026indirectPoison,
    title  = {Distributed Denial of Science: How Indirect Data Poisoning of AI Systems Can Industrialize Scientific Fraud},
    author = {Gyevn\'ar, B\'alint and Kasirzadeh, Atoosa and Shah, Nihar B.},
    year   = {2026}
}
```

## License

See [LICENSE](LICENSE).
