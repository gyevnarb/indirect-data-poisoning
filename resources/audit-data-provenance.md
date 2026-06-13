---
name: audit-data-provenance
description: "Audit a single dataset's provenance and validity by running parallel checks (paper verification, social credibility, statistical anomalies, cross-dataset consistency, poisoning risk) and synthesizing a provenance report. Use when evaluating dataset trustworthiness, preparing data for scientific analysis, and/or when the user mentions data quality, provenance, dataset auditing, or data poisoning."
---

# SKILL.md

You are a data provenance orchestrator. Your job is to audit a dataset by launching five parallel sub-agents, collecting their reports, and synthesizing a final provenance assessment.

## Data Provenance Workflow

Copy this checklist to track your progress:

```
Data Provenance Workflow:
- [ ] Step 1: Spawn Parallel Agents:
  - [ ] Step 1a: Related Paper Verification
  - [ ] Step 1b: Social Credibility Checks
  - [ ] Step 1c: Statistical Anomaly Checks
  - [ ] Step 1d: Cross-Dataset Consistency
  - [ ] Step 1e: Poisoning Risk
- [ ] Step 2: Synthesize Provenance Report
- [ ] Step 3: Output Provenance Report
```

### Step 1: Spawn Parallel Agents

Launch five sub-agents simultaneously.

Structure the agent prompt with this template:
```
You are a specialized agent responsible for <task_name>. Your task is to evaluate the dataset located at <dataset_path> according to the following specific instructions:

<instructions>

**Rules**:
- Use the already installed `datasets` CLI tool to retrieve dataset metadata and statistics. Run `datasets --help` to discover available subcommands.
- If any required information (datasets, metrics, citations, or comparisons) cannot be reliably found and/or retrieved, explicitly state this instead of guessing or fabricating.

**Output**:
- Format your output as a structured report with sections: Assessment, Evidence/Findings, and Reasoning.
- Be concise but thorough.
- Optimize for clarity and parsability — this report will be read by an orchestrating agent, not a human.
```

Replace for each Step 1 sub-agent:
- <task_name> with the specific task description for that agent
- <dataset_path> with the path to the dataset being audited
- <instructions> with the specific instructions for that agent


#### Step 1a: Related Paper Verification

<task_name>:
```Related Paper Verification```

<instructions>:
```
**Related Paper Verification**: Determine whether each dataset is referenced or used in at least one credible scientific publication. Prefer peer-reviewed venues; arXiv is acceptable but must be labeled.
   * Output: A. Assessment: VERIFIED | NOT VERIFIED; B. Evidence: Title, Authors, Year, Venue, DOI/URL.
   * Rules: 1. Do NOT fabricate citations, DOIs, or URLs; 2. Omit any uncertain or unverifiable sources; 3. Prefer fewer high-confidence sources over many uncertain ones. 4. If no credible source is found, return: Status: NOT VERIFIED.
```

#### Step 1b: Social Credibility Checks

<task_name>:
```Social Credibility Checks```

<instructions>:
```
**Social Credibility Checks**: Evaluate the social credibility of each dataset using observable social and usage markers. Identify measurable indicators such as downloads, views, stars, forks, upvotes, likes, bookmarks, platform-level citation/mention counts, and inclusion in curated lists or benchmarks, using multiple independent signals where possible.
   * Output: A. Assessment: HIGH SIGNAL | MODERATE SIGNAL | LOW SIGNAL | NO SIGNAL; B. Signal summary: List each signal with its value and source (URL if available).
   * Rules: 1. Do NOT infer signals that are not explicitly observable; 2. Do NOT fabricate metrics or platform statistics; 3. Treat low or missing signals as meaningful (do not compensate with assumptions). 4. If signals conflict (e.g., high downloads but low engagement), explain the discrepancy.
```

#### Step 1c: Statistical Anomaly Checks

<task_name>:
```Statistical Anomaly Checks```

<instructions>:
```
**Statistical Anomaly Checks**: Perform quick checks for each dataset for obvious statistical anomalies using simple metrics, such as range, mean, median, standard deviation, missing rate, duplicates, basic distributions. Look for impossible values, extreme outliers, unusual spikes or uniformity, inconsistent units, or suspiciously low variance.
   * Output: A. Assessment: NO OBVIOUS ISSUES | MINOR ANOMALIES | SIGNIFICANT ANOMALIES; B. Findings (list anomalies or notable patterns).
   * Rules: 1. Use only simple, fast computations (no complex models or heavy tests); 2. Do not fabricate or assume missing data; 3. Flag anomalies without concluding invalidity; 4. State explicitly if data is insufficient for analysis.
```

#### Step 1d: Cross-Dataset Consistency

<task_name>:
```Cross-Dataset Consistency```

<instructions>:
```
**Cross-Dataset Consistency**: Retrieve multiple datasets on the same or closely related topic and compare them for consistency in scale, distributions, schema, and key statistics to identify major discrepancies or alignment.
   * Output: A. Assessment: CONSISTENT | PARTIALLY CONSISTENT | INCONSISTENT | INSUFFICIENT DATA; B. Retrieved datasets: Names, Brief description, Source URLs/DOIs; C. Comparison findings: Key similarities and differences in size, features, ranges, distributions, or structure.
   * Rules: 1. Use at least 2-3 independent datasets where possible; 2. Do not fabricate datasets or sources; 3. Prefer well-known or widely used datasets; 4. Focus on high-level, fast comparisons (no heavy computation); 5. Note differences in scope, definitions, or units before judging inconsistency; 6. If insufficient comparable datasets are found, state this explicitly.
```

#### Step 1e: Poisoning Risk

<task_name>:
```Poisoning Risk```

<instructions>:
```
**Poisoning Risk**: Evaluate whether the dataset may have been intentionally manipulated to bias or distort results by looking for systematic (non-random) anomalies, directional patterns that skew outcomes, inconsistencies across subsets or time, suspicious or unclear provenance/metadata, discrepancies with established facts or independent datasets, or overly clean/synthetic-looking data.
   * Output: A. Assessment (NO CLEAR RISK | POSSIBLE RISK | HIGH RISK); B. Findings (specific signals observed); C. Reasoning (brief justification)
   * Rules: 1. Distinguish intentional manipulation from natural noise or data issues; 2. DO NOT assume poisoning without evidence; 3. Prefer multiple supporting signals over single anomalies; 4. If evidence is weak or ambiguous, classify as POSSIBLE RISK and explain uncertainty.
```

### Step 2: Synthesize Provenance Report

Wait for ALL five sub-agents to finish and return their reports.

Synthesize all outputs of the sub-agents into a single **Data Provenance Report**. Structure the Data Provenance Report with this template:
```
# Data Provenance Report

**Dataset**: <dataset_path>
**Overall Risk Level**: <your synthesized assessment: LOW / MODERATE / HIGH / CRITICAL>

## 1. Related Paper Verification
<summarize Step 1a: Related Paper Verification findings>

## 2. Social Credibility
<summarize Step 1b: Social Credibility findings>

## 3. Statistical Sanity Checks
<summarize Step 1c: Statistical Sanity Checks findings>

## 4. Cross-Dataset Consistency
<summarize Step 1d: Cross-Dataset Consistency findings>

## 5. Poisoning Risk Assessment
<summarize Step 1e: Poisoning Risk Assessment findings>

## 6. Overall Assessment
<synthesize all five steps, highlighting key risks and confidence levels>

## 7. Recommendation
<PROCEED / PROCEED WITH CAUTION / DO NOT USE>
```

### Step 3: Output Provenance Report

Write the full Data Provenance Report to `DATA_PROVENANCE_REPORT_<dataset_id>.md` in the current working directory. Replace <dataset_id> with the name of the dataset.

Inform the user of the Data Provenance Report, using ## 6. Overall Assessment and ## 7. Recommendation, with this template:
```
# Data Provenance Assessment Result

**Overall Assessment**: <your synthesized summary from ## 6. Overall Assessment of the Data Provenance Report>

**Recommendation**: <your recommendation from ## 7. Recommendation of the Data Provenance Report>
```

## Out of scope
- This skill does not perform full adversarial robustness testing.
- This skill does not clean or repair datasets — it only assesses them.