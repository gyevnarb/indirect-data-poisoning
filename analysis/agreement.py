from collections import Counter
from pathlib import Path

import pandas as pd

CSV_PATH = "mitigation.csv"
EXCLUDE_QIDS = []

# Unify divergent label vocabularies across annotators before scoring.
NORMALIZE = {
    "no": "neg",
    "not_detected": "neg",
    "partial": "partial",
    "partially_detected": "partial",
    "unclear": "na",
    "not_applicable": "na",
}


def kappa(a, b):
    """Compute Cohen's kappa for two equal-length sequences of labels.

    Returns a ``(po, pe, k)`` tuple: ``po`` is the observed agreement (the
    fraction of positions where ``a`` and ``b`` match), ``pe`` is the agreement
    expected by chance given each annotator's marginal label frequencies, and
    ``k`` is the chance-corrected kappa ``(po - pe) / (1 - pe)``. ``k`` is NaN
    when ``pe == 1`` (both annotators used a single, identical label).
    """
    n = len(a)
    po = sum(1 for x, y in zip(a, b) if x == y) / n
    ca, cb = Counter(a), Counter(b)
    pe = sum((ca[c] / n) * (cb[c] / n) for c in set(ca) | set(cb))
    k = (po - pe) / (1 - pe) if (1 - pe) else float("nan")
    return po, pe, k


def hrule(char="─", width=72):
    """Print a horizontal rule of ``width`` repetitions of ``char``."""
    print(char * width)


def find_data_dir(rel="results/eval/human"):
    """Locate `rel` by walking up from this script's directory.

    Robust to the current working directory: the repo layout has this script
    in `<root>/analysis/` and the data in `<root>/results/eval/human/`.
    """
    for base in [Path(__file__).resolve().parent, *Path(__file__).resolve().parents]:
        candidate = base / rel
        if candidate.is_dir():
            return candidate
    raise FileNotFoundError(
        f"Could not locate '{rel}' above {Path(__file__).resolve()}"
    )


def print_kappa(path=CSV_PATH):
    """Load an annotation CSV and print a Cohen's kappa agreement report.

    Reads the CSV at ``path``, drops rows whose ``qid`` is in ``EXCLUDE_QIDS``,
    and normalizes the ``value`` labels via ``NORMALIZE`` to unify divergent
    vocabularies. The data is pivoted to one row per ``(run_id, qid)`` with one
    column per annotator; exactly two annotators are required (raises
    ``ValueError`` otherwise).

    Only items both annotators labelled (no NaN) are scored. Prints the overall
    observed/expected agreement and kappa, followed by a per-qid breakdown
    sorted by descending disagreement count then ascending observed agreement.
    """
    df = pd.read_csv(path)
    df = df[~df["qid"].isin(EXCLUDE_QIDS)].copy()
    df["value_norm"] = df["value"].astype(str).map(lambda v: NORMALIZE.get(v, v))

    wide = df.pivot_table(
        index=["run_id", "qid"],
        columns="annotator",
        values="value_norm",
        aggfunc="first",
    )

    annotators = wide.columns.tolist()
    if len(annotators) != 2:
        raise ValueError(f"Expected 2 annotators, found: {annotators}")
    a_col, b_col = annotators

    paired = wide.dropna()
    a, b = paired[a_col].tolist(), paired[b_col].tolist()
    po, pe, k = kappa(a, b)

    hrule("═")
    print(f"  Cohen's kappa — {a_col} vs {b_col} - {Path(path).name}")
    hrule("═")
    print(f"  Paired items:        {len(paired)} (of {len(wide)} total)")
    print(f"  Excluded qids:       {', '.join(EXCLUDE_QIDS)}")
    print(f"  Observed agreement:  {po:.4f}")
    print(f"  Expected agreement:  {pe:.4f}")
    print(f"  Cohen's kappa:       {k:.4f}")

    hrule()
    print("  Per-qid breakdown (sorted by disagreement)")
    hrule()
    print(f"  {'qid':<22}{'n':>4}{'disagree':>10}{'p_o':>8}{'kappa':>8}")
    hrule("┄")
    rows = []
    for qid, sub in paired.reset_index().groupby("qid"):
        xa, xb = sub[a_col].tolist(), sub[b_col].tolist()
        ppo, _, pk = kappa(xa, xb)
        rows.append((qid, len(xa), sum(1 for x, y in zip(xa, xb) if x != y), ppo, pk))
    for qid, n, dis, ppo, pk in sorted(rows, key=lambda r: (-r[2], r[3])):
        print(f"  {qid:<22}{n:>4}{dis:>10}{ppo:>8.3f}{pk:>8.3f}")
    hrule("═")


if __name__ == "__main__":
    data_dir = find_data_dir()
    print_kappa(data_dir / "baseline.csv")
    print()
    print()
    print_kappa(data_dir / "mitigation.csv")
