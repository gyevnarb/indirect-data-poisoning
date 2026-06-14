# Distributed Denial of Science: How Indirect Data Poisoning of AI Systems Can Industrialize Scientific Fraud

This repository contains the supplementary materials for the paper titled "Distributed Denial of Science: How Indirect Data Poisoning of AI Systems Can Industrialize Scientific Fraud".
The paper can be found [here]().

## Contents

The repository contains the following high-level folders:
- `analysis`: Contains scripts used to analyze the contents of the `results/` folder. Use these to reproduce the figures in the paper.
- `data`: Contains the following data files:
    - `poisoned.zip`: A password-protected ZIP file with the poisoned datasets, code used for poisoning, and the misleading metadata files. Please submit an access request using the form [below](#data-access-request) to access the data.
    - `scientist-persona.md`: The scientist persona system prompt.
    - `audit-data-provenance.md`: The provenance audit SKILL file. Move this to your agent's skills folder following the documentation of your agent's provider.
- `results`: Contains all experimental results, further broken down as follows:
    - `eval`: Raw evaluation results from the LLM-as-a-judge setup (folder `llm`), as well as the human annotations on a subset of both the baseline runs and the mitigation runs (folder `human`) used for cross-checking.
    - `runs.zip`: A password-protected ZIP with full experimental runs with trace logs and code written by the AI agent. Please submit an access request using the form [below](#data-access-request) to access this data.
    - `full.csv`: A convenient CSV with all our evaluation results in tabular format.
    - `provenance.csv`: A convenient CSV containing the provenance audit scores and assessment scores for all five sub-tasks
    - `dataset_downloads.csv`: A list of datasets downloaded by the AI agents during their experiments. Extracted from trace logs.
- `scripts`: Contains all scripts necessary to reproduce our results.
- `src`: Source code for the wrapper around the open data platforms.

## Please cite

If you rely on our work in your project, we would appreciate you citing it in. Please use the below bibtex entry in your bibliography file:
```latex
@misc{gyevnar2026indirectPoison,
    title = {Distributed Denial of Science: How Indirect Data Poisoning of AI Systems Can Industrialize Scientific Fraud}
    authors = {Gyevn\'ar, B\'alint and Kasirzadeh, Atoosa and Shah, Nihar B.},
    year = {2026}
}
```

## How to reproduce our results

The following sections give detailed steps on how to fully reproduce our results.

On a high level, the experiment follows the below steps. If you do not want to use poisoned data, then you can skip step 2.
1. [Installing requirements](#1-requirements)
2. [Uploading poisoned dataset to private repositories](#2-set-up-data-repositories)
3. [Running the experiments](#3-running-the-experiment)
4. Evaluating experiments
5. Analyses and plotting

### 1. Requirements

In order to successfully reproduce our results, you should have the following installed:

- **Docker**: we use Docker to parallelize runs, remove any confounding system information from the AI's view, and to avoid harmful side effects. You can install from [here](https://www.docker.com/products/docker-desktop/).
- **datasets**: this is the open data platform API-call wrapper. Install this using the instructions [below](#data-platform-wrapper).
- **Python 3.14**: for processing data after the experiments are run. The experiments themselves do not need Python 3.14 installed locally, as the Docker container sets up dependencies automatically. I recommend using [uv](https://docs.astral.sh/uv/getting-started/installation/) to manage your local virtual environment for Python.
- **R v4.6.0**: for plotting figures and statistical tests. This is again not required for running the experiments themselves. Can be installed from [here](https://www.r-project.org/).

### 2. Set up data repositories

Before you get started with running the experiments, you have to make sure that the data is actually available for the AI agents to find online. 
To avoid spreading misinformation everything must be done using private repositories. 
To set up these repositories, you should follow these steps:

1. Obtain access to and extract `poisoned.zip`, which contains the poisoned datasets. This file comes with the following folders, corresponding to the *DATA_ID* of each topic tested in the paper:
    - `3hu9k`: The Philadelphia Traffic Policing Dataset.
    - `6jmfx`: Dataset on the intrinsic motivational cost of using generative AI.
    - `av`: Datasets to compare the safety of autonomous vehicles and human drivers.
    - `hiring`: Minor hiring disparity in professional workplace settings.
    - `fertility`: Various demographic indicators of and related to fertility rates in Europe.
2. Select which adversary-goal version to upload. Things to note:
    - The poisoned data within each topic is in a folder called `poisoned`.
    - Files containing the word "negative" correspond to the reject-adversary goal from the paper.
    - Files containing the word "positive" correspond to the exaggerate-adversary goal.
    - Files containing neither "positive" nor "negative" should always be uploaded, regardless of the adversary goal you have selected
3. Create **private** repos for each dataset. For the paper, we uploaded each topic to the following platforms, with repo names in parentheses:
    - 3hu9k -> *Open Science Framework* (Extended Philadelphia Open Traffic Policing Dataset)
    - 6jmfx -> *Open Science Framework* (Positive: "Replication: Human-Generative AI Collaboration Enhances Task Performance but *Strongly* Undermines Human’s Intrinsic Motivation in Sequential Tasks" / Negative: "Increasing Task Performance and Intrinsic Motivation in Human-Generative AI Collaboration")
    - av -> *HuggingFace* (autonomous-vehicle-human-traffic-accidents-safety-california)
    - hiring -> *Kaggle* (the-state-of-hiring-discrimination-extended-data)
    - fertility -> *GitHub* (fertility-rate-collapse-europe)
4. Upload each dataset to the **private** repo.
    - The dataset consists of (1) data files (CSV or ZIP), (2) a README file, and (3) data loading code.
    - The `DESCRIPTION_*.md` file contains a description to use in metadata.
    - Make sure to rename each file you upload to remove the phrases `_negative` or `_positive`. This avoids suggesting to the AI agent that the is in some way manipulated.
5. You can test whether your data can be found by searching for it with the `datasets` tool:
    - Make sure the platform API tokens are set in your environment (see below on which platform uses which environment variable name).
    - Run the command: `datasets <platform_name> search <your_query>`, where platform_name can be {osf, hf, kaggle, github}. For example a valid query is `datasets osf search "generative AI intrinsic motivation" --limit 25`.

**Important note for OSF:** Queries through the OSF API can be extremely slow. To speed up the process, the `datasets` command provides an option to scrape the full OSF database and create an inverted index from that. You can follow the `--help` messages for the (hidden) commands `dastasets osf fetch` and `datasets osf index` to obtain the inverted index. This process can take up to a day to finish, when running constantly, though saving is enabled at regular intervals so the process can be stopped, resumed, and updated.

### 3. Running the experiment

To make sure everything runs as expected, follow these steps:
1. Create a new folder where you will want to run the experiments. 
2. Copy the contents of the `scripts/` folder into this new folder. 
3. Decide which experimental conditions to run. Rename the file you select to `interventions.json`:
    - The file `interventions_all.json` contain all six condition tested in the paper. This is just a combination of the below two files.
    - The file `interventions_baseline.json` contains all baseline experimental conditions.
    - The file `interventions_mitigations.json` contains all mitigation measure experimental conditions.
4. Create a `.env` file in the folder where you are running the experiments, and fill out each key with your own. The tokens should allow full read access to each data platform:
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
6. Run the experiments. You have three options on how to do this depending on your required level of automation:
    - To run all experiments for a given agent, run the script `bash a.ll_experiments.sh -s --build [AGENT <claude|codex|gemini|fable>] [-- EXTRA_ARGS...]`. The text in <EXTRA_ARGS> are passed verbatim to the `batch_run.sh` script.
    - To execute experiments for a single dataset, run the script `bash batch_run.sh -s --build <DATA_ID> [RUN_INTERVENTION_OPTIONS...]` replacing `<DATA_ID>` with one {6jmfx, 3hu9k, av, hiring, fertility}. The contents of `<RUN_INTERVENTION_OPTIONS>` are passed directly to the script `run_intervention.sh`. 
    - **Do not run** `run_intervention.sh` **on its own as it does not perform dockerization, and it may execute potentially harmful code on your local machine.**
    - You can run each script without command line arguments or options to show some help messages.
    - Each script accepts a `-n` option which runs the script in a dry-run mode.
7. Check experimental results in the folders `workspace` and `logs`.
    - You can track how the current experiments are proceeding by checking these folders while the experiments are running. This is useful to catch if something is going wrong so you can stop script execution in time.

Example scripts to run:
```bash
# Run all experimental conditions in interventions.json for DATA_ID 6jmfx with k=7 iterations per condition, each iteration running sequentially (-s), with the Docker image re-built (--build), using Codex (-a), in dry-run mode (-n)
bash batch_run.sh -n -s --build 6jmfx -a codex -k 7

# Run all dataset experiments for all conditions in interventions.json with k=3 iterations per condition, in sequential mode.
bash all_experiments.sh -s claude -- -k 3
```




### 4. Evaluate the experiments

You can run the script `analysis/agreement.py` to calculate Cohen's kappa between the LLM-as-a-judge and the human annotator for both the baseline and mitigation measure runs. The data for this comes from the folder `results/eval/human/{baseline,mitigation}.csv`, where each CSV already contains the evaluation scores for both the LLM and the human.

### Figures



## Data platform wrapper

This is a smaller helper package that combines several sources for datasets loading.
It 
The currently supported providers are:
- GitHub
- Open Source Framework (OSF)
- Kaggle
- HuggingFace (HF)
- OpenML (not used in experiments; hidden from AI)


### Usage

To use the package, I recommend [uv](https://docs.astral.sh/uv/getting-started/installation/).
Run the following commands to start using the package:
```bash
uv tool install -e .  # Run for repo root
```

In addition, to use each source, you must have the appropriate API access enabled.
For each dataset source this means the following:
- GitHub: set the `GITHUB_TOKEN` environment variable for authenticated requests and higher rate limits.
- Kaggle: set the `KAGGLE_API_TOKEN` environment variable (or other authentication methods as instructed by Kaggle).
- HuggingFace: set the `HF_TOKEN` environment variable.
- OSF: set the `OSF_TOKEN` environment variable.
- OpenML: No API key is needed for searching and downloading. For uploading datasets you need to follow the OpenML authentication guidelines online.

## Data access request

As our poisoning data and full run results may contain sensitive and potentially harmful or misleading, these files are protected by password.
In order to access these files, please fill out [this form]() (not yet live) with relevant information and acknowledgements.