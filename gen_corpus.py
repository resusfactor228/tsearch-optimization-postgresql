#!/usr/bin/env python3
"""
Corpus generator for FTS uid experiment.
Reads /usr/share/dict/words, produces N documents to stdout (one per line).
Each document is a random sequence of 50–200 English words.

Usage:
    python3 gen_corpus.py | psql -U postgres -d fts_bench -c "COPY docs(body) FROM STDIN"
    python3 gen_corpus.py --docs 100000 > /tmp/corpus_sample.txt
"""

import argparse
import random
import sys

VOCAB_SOURCE = "/usr/share/dict/words"
VOCAB_SIZE   = 50_000
SEED         = 42


def load_vocab(path: str, size: int) -> list[str]:
    with open(path) as f:
        words = [w.strip().lower() for w in f
                 if w.strip().isalpha() and 3 <= len(w.strip()) <= 12]
    # deduplicate, preserve encounter order
    seen: set[str] = set()
    unique: list[str] = []
    for w in words:
        if w not in seen:
            seen.add(w)
            unique.append(w)
        if len(unique) == size:
            break
    if len(unique) < size:
        sys.stderr.write(
            f"Warning: only {len(unique)} words found (wanted {size})\n"
        )
    return unique


def main() -> None:
    parser = argparse.ArgumentParser(description="Generate FTS benchmark corpus")
    parser.add_argument("--docs",  type=int, default=500_000,
                        help="number of documents to generate (default: 500000)")
    parser.add_argument("--min-words", type=int, default=50,
                        help="minimum words per document (default: 50)")
    parser.add_argument("--max-words", type=int, default=200,
                        help="maximum words per document (default: 200)")
    parser.add_argument("--seed", type=int, default=SEED,
                        help="random seed (default: 42)")
    parser.add_argument("--vocab", type=str, default=VOCAB_SOURCE,
                        help="path to word list (default: /usr/share/dict/words)")
    args = parser.parse_args()

    rng = random.Random(args.seed)

    sys.stderr.write(f"Loading vocabulary from {args.vocab}...\n")
    vocab = load_vocab(args.vocab, VOCAB_SIZE)
    sys.stderr.write(f"Vocabulary size: {len(vocab)} words\n")
    sys.stderr.write(f"Generating {args.docs:,} documents "
                     f"({args.min_words}–{args.max_words} words each)...\n")

    out = sys.stdout
    for i in range(args.docs):
        n = rng.randint(args.min_words, args.max_words)
        line = " ".join(rng.choices(vocab, k=n))
        out.write(line)
        out.write("\n")
        if (i + 1) % 50_000 == 0:
            sys.stderr.write(f"  {i + 1:,} / {args.docs:,}\n")

    sys.stderr.write("Done.\n")


if __name__ == "__main__":
    main()
