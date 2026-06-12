# Distributed Denial of Science: How Indirect Data Poisoning of AI Systems Can Industrialize Scientific Fraud

This repository contains the supplementary materials for the paper titled "Distributed Denial of Science: How Indirect Data Poisoning of AI Systems Can Industrialize Scientific Fraud".
The paper can be found [here]().

## Contents

The repository contains the following high-level folders:
- `analysis`: Contains scripts used to analyze the contents of the `results/` folder. Use these to reproduce the figures in the paper.
- `resources/`: Contains the following resource files:
    - `poisoned.zip`: A single password-protected ZIP file with the poisoned datasets, code used for poisoning, and the misleading metadata files. Please contact the first author per email found in the paper.
    - `scientist-persona.md`: The scientist persona system prompt.
    - `provenance-audit.md`: The provenance audit SKILL file. Move this to your agent's skills folder following the documentation of your agent's provider.
- `results/`: Contains all experimental results, further broken down as follows:
    - `runs/`: Full experimental runs with trace logs and code written by the AI agent.
    - `eval/`: Evaluation results from the LLM-as-a-judge setup, as well as the human annotations used for cross-checking.
    - `results.csv`: A convenient CSV with all our evaluation results in tabular format.
    - `provenance.csv`: A convenient CSV containing the provenance audit scores and assessment scores for all five sub-tasks
- `scripts/`: Contains all scripts necessary to reproduce our results.
- `src/`: Source code for the wrapper around the open data platforms.

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

### Requirements

In order to successfully reproduce our results, you must have the following installed:

- **Docker**: we use Docker to parallelize runs, remove any confounding system information from the AI's view, and to avoid harmful side effects. You can install from [here](https://www.docker.com/products/docker-desktop/).
- **datasets**: this is the open data platform API-call wrapper. Install this using the instructions [below](#data-platform-wrapper).
- **poisoning.zip**: The poisoned data. For each dataset, you will need to upload it to a private repo as follows:
    1. Select which adversary-goal version to upload: files containing the word "negative" correspond to the reject-adversary goal from the paper; "positive" correspond to the exaggerate-adversary goal.
    2. Upload the dataset to a **private** repo. The dataset consists of the data files, a README file, a DESCRIPTION file to use in metadata, and a data loading code snippet. Each dataset should be uploaded to the following platform to guarantee the most faithful reproduction (though other provides should also work):
        - `3hu9k (Traffic Policing)`: OSF
        - `6jmfx (GenAI Motivation)`:  OSF
        - `av (AV Safety)`: HuggingFace
        - `hiring (Hiring)`: Kaggle
        - `fertility (Fertility Rates)`: GitHub
    3. (Optional, but recommended): For OSF, queries can be extremely slow. To speed up the process, the `datasets` command provides an option to scrape the full OSF database and create an inverted index from that. You can followed the `--help` messages for the hidden commands `dastasets osf fetch` and `datasets osf index` to obtain the inverted index. This process can take up to a day to finish, when running constantly, though saving 

### Set up

To make sure everything runs as expected, follow these steps:
1. Create a new folder where you will want to run the experiments. 
2. Copy the contents of the `scripts/` folder into this new folder. 
3. Decide which experiments to run:



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
uv tool install "git+https://github.com/gyevnarb/datasets"
```

In addition, to use each source, you must have the appropriate API access enabled.
For each dataset source this means the following:
- GitHub: set the `GITHUB_TOKEN` environment variable for authenticated requests and higher rate limits.
- Kaggle: set the `KAGGLE_API_TOKEN` environment variable (or other authentication methods as instructed by Kaggle).
- HuggingFace: set the `HF_TOKEN` environment variable.
- OSF: set the `OSF_TOKEN` environment variable.
- OpenML: No API key is needed for searching and downloading. For uploading datasets you need to follow the OpenML authentication guidelines online.
