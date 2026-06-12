"""Utility functions for datasets package."""

import re
import secrets
import string
from typing import Any

import bm25s
from nltk.corpus import stopwords
from nltk.stem import PorterStemmer
from rich.console import Console

_FALLBACK_STOPWORDS = {
    "a",
    "about",
    "an",
    "and",
    "are",
    "as",
    "at",
    "be",
    "been",
    "being",
    "but",
    "by",
    "for",
    "from",
    "if",
    "in",
    "into",
    "is",
    "it",
    "its",
    "of",
    "on",
    "or",
    "out",
    "over",
    "the",
    "these",
    "this",
    "those",
    "to",
    "under",
    "was",
    "were",
    "while",
    "with",
}
_STOPWORDS: set[str] | None = None
_STEMMER = PorterStemmer()
_TOKENIZER_PATTERN = re.compile(r"\b(?!\d+\b)[^\W_]+\b")

console = Console()


def _get_stopwords() -> set[str]:
    global _STOPWORDS  # noqa: PLW0603
    if _STOPWORDS is None:
        try:
            _STOPWORDS = set(stopwords.words("english"))
        except LookupError:
            _STOPWORDS = _FALLBACK_STOPWORDS
    return _STOPWORDS


def preprocess(text: str) -> list[str]:
    """Preprocess text for indexing and search.

    Steps: lowercase, strip, tokenize, remove stopwords, stem.
    """
    if not text:
        return []

    normalized = text.lower().strip()
    if not normalized:
        return []

    tokens = _TOKENIZER_PATTERN.findall(normalized)
    if not tokens:
        return []

    stopword_set = _get_stopwords()
    return [
        _STEMMER.stem(token)
        for token in tokens
        if token not in stopword_set and len(token) > 1
    ]


def random_string(length: int) -> str:
    """Return a random alphanumeric string with the given length.

    Args:
        length: Number of characters in the generated string.

    Returns:
        Random string containing characters in [a-zA-Z0-9].

    Raises:
        ValueError: If length is negative.

    """
    if length < 0:
        raise ValueError

    alphabet = string.ascii_letters + string.digits
    return "".join(secrets.choice(alphabet) for _ in range(length))


def normalize_path(raw_path: str | None) -> str | None:
    """Normalize path by stripping whitespace and removing leading/trailing slashes.

    Args:
        raw_path: Raw file path string (can be None)

    Returns:
        Normalized path string without leading/trailing slashes, or None

    """
    if not raw_path:
        return None
    normalized = raw_path.strip()
    normalized = normalized.removeprefix("/")
    normalized = normalized.removesuffix("/")
    return normalized or None


def format_file_size(size: int | str | None) -> str:
    """Format file size in human-readable format.

    Args:
        size: File size in bytes (int) or any other value

    Returns:
        Formatted string with appropriate unit (B, KB, MB, GB)

    """
    two_pow_10 = 1024
    if isinstance(size, int):
        if size < two_pow_10:
            return f"{size} B"
        if size < two_pow_10**2:
            return f"{size / 1024:.1f} KB"
        if size < two_pow_10**3:
            return f"{size / (two_pow_10**2):.1f} MB"
        return f"{size / (two_pow_10**3):.1f} GB"
    return str(size) if size is not None else "N/A"


def extract_actor(log: dict[str, Any]) -> str | None:
    """Extract actor (user) information from a log entry in the OSF API response."""
    embeds = log.get("embeds", {})
    for key in ("user", "users", "logged_user", "target_user"):
        embedded = embeds.get(key, {})
        embedded_data = embedded.get("data", embedded)

        if isinstance(embedded_data, dict):
            embedded_attrs = embedded_data.get("attributes", {})
            full_name = embedded_attrs.get("full_name")
            if full_name:
                return str(full_name)
            embedded_id = embedded_data.get("id")
            if embedded_id:
                return f"user:{embedded_id}"

        if isinstance(embedded_data, list):
            for item in embedded_data:
                item_attrs = item.get("attributes", {})
                full_name = item_attrs.get("full_name")
                if full_name:
                    return str(full_name)
                item_id = item.get("id")
                if item_id:
                    return f"user:{item_id}"

    relationships = log.get("relationships", {})
    for key in ("user", "logged_user", "target_user", "foreign_user"):
        rel = relationships.get(key, {})
        rel_data = rel.get("data")
        if isinstance(rel_data, dict):
            rel_id = rel_data.get("id")
            if rel_id:
                return f"user:{rel_id}"
        if isinstance(rel_data, list):
            for item in rel_data:
                rel_id = item.get("id")
                if rel_id:
                    return f"user:{rel_id}"

    params = log.get("attributes", {}).get("params") or {}
    for key in ("full_name", "name", "user", "user_id", "actor"):
        value = params.get(key)
        if value:
            return str(value)

    return None


class BM25Scorer:
    """BM25 scorer backed by the bm25s library."""

    def __init__(self, k1: float = 1.5, b: float = 0.75) -> None:
        """Initialize BM25 scorer.

        Args:
            k1: Controls term frequency saturation (default: 1.5)
            b: Controls length normalization (default: 0.75)

        """
        self.k1 = k1
        self.b = b

    def score(self, query: str, documents: list[str]) -> list[float]:
        """Calculate BM25 scores for documents given a query.

        Args:
            query: Search query string
            documents: List of document strings to score

        Returns:
            List of BM25 scores (higher is more relevant)

        """
        if not documents or not query:
            return [0.0] * len(documents)

        stemmer = lambda tokens: [_STEMMER.stem(t) for t in tokens]  # noqa: E731
        corpus_tokens = bm25s.tokenize(
            documents, stopwords="english", stemmer=stemmer, show_progress=False,
        )
        query_tokenized = bm25s.tokenize(
            [query], stopwords="english", stemmer=stemmer, show_progress=False,
        )

        retriever = bm25s.BM25(k1=self.k1, b=self.b)
        retriever.index(corpus_tokens, show_progress=False)

        # get_scores expects List[str]; extract from the Tokenized object
        inv_vocab = {v: k for k, v in query_tokenized.vocab.items()}
        query_token_strs = [inv_vocab[i] for i in query_tokenized.ids[0]]

        if not query_token_strs:
            return [0.0] * len(documents)

        return retriever.get_scores(query_token_strs).tolist()
