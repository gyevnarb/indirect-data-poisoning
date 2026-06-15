# Distributed Denial of Science: How Indirect Data Poisoning of AI Systems Can Industrialize Scientific Fraud

This repository contains the supplementary materials for the paper "Distributed Denial of Science: How Indirect Data Poisoning of AI Systems Can Industrialize Scientific Fraud".
The paper can be found [here]().

### Table of Contents

- [File Contents](#file-contents)
- [Data Access](#data-access)
- [Reproduce Experiments](#reproduce-experiments)
- [Dataset Wrapper](#dataset-wrapper)

### Please Cite

If you rely on our work in your project, we would appreciate a citation. Please use the BibTeX entry below in your bibliography file:
```bibtex
@misc{gyevnar2026indirectPoison,
    title  = {Distributed Denial of Science: How Indirect Data Poisoning of AI Systems Can Industrialize Scientific Fraud},
    author = {Gyevn\'ar, B\'alint and Kasirzadeh, Atoosa and Shah, Nihar B.},
    year   = {2026}
}
```

## File Contents

The repository contains the following high-level folders:
- `analysis`: Contains scripts used to analyze the contents of the `results/` folder. Use these to reproduce the figures in the paper.
- `data`: Contains the following data files:
    - `poisoned.zip`: A password-protected ZIP file with the poisoned datasets, the code used for poisoning, and the misleading metadata files. Please submit an access request as described [below](#data-access) to access this data.
    - `scientist-persona.md`: The scientist persona system prompt.
    - `audit-data-provenance.md`: The provenance audit SKILL file. Move this to your agent's skills folder following the documentation of your agent's provider.
- `results`: Contains all experimental results, further broken down as follows:
    - `eval`: Raw evaluation results from the LLM-as-a-judge setup (folder `llm`), as well as the human annotations on a subset of both the baseline runs and the mitigation runs (folder `human`) used for cross-checking.
    - `runs.zip`: A password-protected ZIP with full experimental runs, including trace logs and code written by the AI agent. Please submit an access request as described [below](#data-access) to access this data.
    - `full.csv`: A convenient CSV with all our evaluation results in tabular format.
    - `provenance.csv`: A convenient CSV containing the provenance audit scores and assessment scores for all five sub-tasks.
    - `dataset_downloads.csv`: A list of datasets downloaded by the AI agents during their experiments, extracted from the trace logs.
- `scripts`: Contains all scripts necessary to reproduce our results.
- `src`: Source code for the wrapper around the open data platforms.

## Data Access

Our poisoning data and full run results may contain sensitive and potentially harmful or misleading information.
These files are therefore protected by a password.

To access these files, please send an email to the first author of the paper, using the email shown in the [paper](), with the exact subject line *Data Request - Distributed Denial of Science* (without surrounding quotation marks).

Please include the following information in your email:
- Your name
- Your affiliation
- A description of why you need access to the data
- A description of how you will process the data

## Reproduce Experiments

The following sections give detailed steps on how to fully reproduce our results.

At a high level, the experiment follows the steps below. If you do not want to use poisoned data, you can skip step 2.
1. [Installing requirements](#1-requirements)
2. [Uploading the poisoned dataset to private repositories](#2-set-up-data-repositories)
3. [Running the experiments](#3-running-the-experiment)
4. [Evaluating the experiments](#4-evaluate-the-experiments)
5. [Analyses and plotting](#5-plot-the-experiments)

Our previous experimental data is already available for your inspection.
This data comes from the folder `results/eval/human/{baseline,mitigation}.csv`, where each CSV already contains the evaluation scores for both the LLM and the human annotator.

You can run the script `analysis/agreement.py` to recalculate Cohen's kappa between the LLM-as-a-judge and our human annotator for both the baseline and mitigation runs.
You can also run `analysis/plots.R` to reproduce the figures of the paper.

### 1. Requirements

The experiments were tested on both Linux (Ubuntu 24.04) and macOS Sequoia 15.7.7. You may run the experiments on Windows using the Windows Subsystem for Linux.
To successfully reproduce our results, you should have the following installed:

- **Docker**: We use Docker to parallelize runs, remove any confounding system information from the AI's view, and avoid harmful side effects. You can install it from [here](https://www.docker.com/products/docker-desktop/).
- **datasets**: This is the open data platform API-call wrapper. Install it using the instructions [below](#dataset-wrapper).
- **Python 3.14**: For processing data after the experiments are run. The experiments themselves do not need Python 3.14 installed locally, as the Docker container sets up its dependencies automatically. I recommend using [uv](https://docs.astral.sh/uv/getting-started/installation/) to manage your local virtual environment for Python.
- **R v4.6.0**: For plotting figures and running statistical tests. This is also not required for running the experiments themselves. It can be installed from [here](https://www.r-project.org/).

### 2. Set up data repositories

Before running the experiments, you have to make sure that the data is actually available for the AI agents to find online.
To avoid spreading misinformation, everything must be done using private repositories.
To set up these repositories, follow these steps:

1. Obtain access to and extract `poisoned.zip`, which contains the poisoned datasets. This file comes with the following folders, corresponding to the *DATA_ID* of each topic tested in the paper:
    - `3hu9k`: The Philadelphia traffic policing dataset.
    - `6jmfx`: Dataset on the intrinsic motivational cost of using generative AI.
    - `av`: Datasets comparing the safety of autonomous vehicles and human drivers.
    - `hiring`: Minor hiring disparities in professional workplace settings.
    - `fertility`: Various demographic indicators of, and related to, fertility rates in Europe.
2. Select which adversary-goal version to upload. Things to note:
    - The poisoned data within each topic is in a folder called `poisoned`.
    - Files containing the word "negative" correspond to the reject-adversary goal from the paper.
    - Files containing the word "positive" correspond to the exaggerate-adversary goal.
    - Files containing neither "positive" nor "negative" should always be uploaded, regardless of the adversary goal you have selected.
3. Create a **private** repo for each dataset. For the paper, we uploaded each topic to the following platforms, with repo names in parentheses:
    - 3hu9k -> *Open Science Framework* (Extended Philadelphia Open Traffic Policing Dataset)
    - 6jmfx -> *Open Science Framework* (Positive: "Replication: Human-Generative AI Collaboration Enhances Task Performance but *Strongly* Undermines Human's Intrinsic Motivation in Sequential Tasks" / Negative: "Increasing Task Performance and Intrinsic Motivation in Human-Generative AI Collaboration")
    - av -> *HuggingFace* (autonomous-vehicle-human-traffic-accidents-safety-california)
    - hiring -> *Kaggle* (the-state-of-hiring-discrimination-extended-data)
    - fertility -> *GitHub* (fertility-rate-collapse-europe)
4. Upload each dataset to its **private** repo.
    - The dataset consists of (1) data files (CSV or ZIP), (2) a README file, and (3) data-loading code.
    - The `DESCRIPTION_*.md` file contains a description to use in the metadata.
    - Make sure to rename each file you upload to remove the phrases `_negative` or `_positive`. This avoids suggesting to the AI agent that the data has been manipulated in any way.
5. You can test whether your data can be found by searching for it with the `datasets` tool:
    - Make sure the platform API tokens are set in your environment (see below for which platform uses which environment variable).
    - Run the command `datasets <platform_name> search <your_query>`, where `platform_name` is one of {osf, hf, kaggle, github}. For example, a valid query is `datasets osf search "generative AI intrinsic motivation" --limit 25`.

**Important note for OSF:** Queries through the OSF API can be extremely slow. To speed up the process, the `datasets` command provides an option to scrape the full OSF database and create an inverted index from it. You can follow the `--help` messages for the (hidden) commands `datasets osf fetch` and `datasets osf index` to obtain the inverted index. This process can take up to a day to finish when running constantly. Saving is enabled at regular intervals, so the process can be stopped, resumed, and updated. Once the inverted index file is ready, copy it to the folder where you are running your experiments (see the next section).

### 3. Running the experiment

**TL;DR:** If you prefer to run a single script, you can execute the following, which performs steps 3-5 automatically (running, evaluating, and analyzing the experiments). This script will create a new folder in your current directory.
```bash
# Push-a-button-style script that performs all of the below for you, but may be more prone to errors.
bash pipeline_run.sh TODO
```

To make sure everything runs as expected, follow the steps below:

1. Create a new folder in which you will run the experiments.
2. Copy the contents of the `scripts/` folder into this new folder.
    - If you are using an OSF inverted index, copy the inverted index file to this new folder as well.
3. Decide which experimental conditions to run. Rename the file you select to `interventions.json`:
    - The file `interventions_all.json` contains all six conditions tested in the paper. It is simply a combination of the two files below.
    - The file `interventions_baseline.json` contains all baseline experimental conditions.
    - The file `interventions_mitigations.json` contains all mitigation-measure experimental conditions.
4. Create a `.env` file in the folder where you are running the experiments, and fill in each key with your own. The tokens should allow full read access to each data platform:
```bash
# API tokens
OSF_TOKEN=xxx
HF_TOKEN=xxx
KAGGLE_API_TOKEN=xxx
GITHUB_TOKEN=xxx
# Model tokens
ANTHROPIC_API_KEY=xxx
GEMINI_API_KEY=xxx
OPENAI_API_KEY=xxx
```
5. Make sure Docker is running.
6. Run the experiments. You have three options, depending on the level of automation you need:
    - To run all experiments for a given agent, run `bash all_experiments.sh -s --build [AGENT <claude|codex|gemini|fable>] [-- EXTRA_ARGS...]`. Everything in EXTRA_ARGS is passed verbatim to the `batch_run.sh` script.
    - To run experiments for a single dataset, run `bash batch_run.sh -s --build <DATA_ID> [RUN_INTERVENTION_OPTIONS...]`, replacing DATA_ID with one of {6jmfx, 3hu9k, av, hiring, fertility}. The contents of `RUN_INTERVENTION_OPTIONS` are passed directly to the `run_intervention.sh` script.
    - **Do not run** `run_intervention.sh` **on its own, as it does not perform dockerization and may execute potentially harmful code on your local machine.**
    - Run any script without command-line arguments or options to show its help message.
    - Each script accepts a `-n` option, which runs the script in dry-run mode.
7. Check experimental results in the `workspace` and `logs` folders.
    - You can track how the experiments are proceeding by checking these folders while the experiments are running. This is useful for catching problems early so you can stop execution in time.

Example scripts to run:
```bash
# Run all experimental conditions in interventions.json for DATA_ID 6jmfx with k=7 iterations per condition, each iteration running sequentially (-s), with the Docker image rebuilt (--build), using Codex (-a), in dry-run mode (-n)
bash batch_run.sh -n -s --build 6jmfx -a codex -k 7

# Run all dataset experiments for all conditions in interventions.json with k=3 iterations per condition, in sequential mode.
bash all_experiments.sh -s claude -- -k 3
```

### 4. Evaluate the experiments

Perform the following steps to run the LLM-as-a-judge evaluation setup:

1. Run `bash copy_results.sh [negative|positive]`.
    - The positional argument corresponds to the adversary goal you selected earlier.
    - This script creates a new folder, `results`, and copies data from the `workspace` and `logs` folders into it.
2. For each DATA_ID, separately run `bash evaluate_batch.sh <DATA_ID> <EVAL_CONFIG_PATH>` to evaluate the experiments for that DATA_ID. The positional argument EVAL_CONFIG_PATH refers to the evaluation schema:
    - For the reject (negative) adversary goal, use `eval_schema_negative.json`.
    - For the exaggerate (positive) adversary goal, use `eval_schema_positive.json`.
3. Collect the results into a CSV by running `python3 annotation_app/export_eval_csv.py -o full.csv`.
    - This produces a CSV file called `full.csv` that should contain all evaluation results in tabular format.

### 5. Plot the experiments

You can use the scripts in the `analysis` folder to reproduce all figures from the paper using your experimental results.
The script currently reproduces figures for our experimental data.
You can replace the following line in `plots.R` (line 39) to point to your own data file:
```R
in_path <- here("..", "results", "full.csv") # <-- Replace this to point to your path
```

## Dataset Wrapper

This repository includes a small helper package that wraps several sources for dataset loading.
The currently supported providers are: GitHub, Open Science Framework (OSF), Kaggle, HuggingFace (HF), and OpenML (not used in the experiments; hidden from the AI).

### Usage

To use the package locally, I recommend [uv](https://docs.astral.sh/uv/getting-started/installation/).
Run the following command to start using the package:
```bash
uv tool install -e .  # Run from the repo root
```

In addition, to use each source you must have the appropriate API access enabled.
For each dataset source, this means the following:
- GitHub: set the `GITHUB_TOKEN` environment variable for authenticated requests and higher rate limits.
- Kaggle: set the `KAGGLE_API_TOKEN` environment variable (or use another authentication method as instructed by Kaggle).
- HuggingFace: set the `HF_TOKEN` environment variable.
- OSF: set the `OSF_TOKEN` environment variable.
- OpenML: no API key is needed for searching and downloading. For uploading datasets, follow the OpenML authentication guidelines online.
