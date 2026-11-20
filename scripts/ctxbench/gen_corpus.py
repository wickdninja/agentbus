#!/usr/bin/env python3
"""Generate scripts/ctxbench/data/corpus.txt, the ctxbench message-body corpus (docs/evals/ctxbench-protocol.md,
"Data files"). Deterministic: a fixed grammar and random.Random(20261119). Stdlib only.

Usage: python3 scripts/ctxbench/gen_corpus.py [--check]   (--check: exit 1 unless the committed file matches)
"""
import os
import random
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "data", "corpus.txt")
SEED = 20261119
LINES = 200
MIN_BYTES, MAX_BYTES = 40, 200
MEAN_LO, MEAN_HI = 90, 130

OPEN = ["", "", "", "Quick update: ", "Heads up, ", "For the record, ", "As of this morning, ", "Before I forget, ",
        "After the last run, ", "Small note: ", "From what I can see, ", "Once the review lands, "]
SUBJECT = ["the retry loop", "the config loader", "the nightly export", "the parser change", "the flaky test",
           "the migration script", "the cache layer", "the new endpoint", "the lint rule", "the fixture data",
           "the release branch", "the error handling", "the timeout path", "the batch job", "the schema change",
           "the upload handler", "the session check", "the rate limiter", "the docs page", "the build step"]
VERB = ["still fails", "now passes", "needs another pass", "looks done", "is blocked", "was rolled back",
        "is half finished", "needs a decision", "is ready for review", "broke on main", "works locally",
        "is slower than expected", "lost its test coverage", "picked up a regression", "is waiting on a reply"]
TAIL = ["", "", " on the second attempt", " when the input is empty", " after the rebase", " under load",
        " with the old fixture", " on the CI runner", " behind the feature flag", " since yesterday",
        " for the large files", " in the staging copy", " with escaped delimiters", " once the cache is warm"]
FOLLOW = ["", "", "", " I will look again after lunch.", " Please do not merge until it is green.",
          " Ping me if you touch the same files.", " The logs are in the usual place.",
          " I have not changed the public interface.", " Reverting is safe if we need to.",
          " The checks I ran are listed in the PR.", " This should not affect the other lanes.",
          " I would rather fix it than skip the test."]


def sentence(rng):
    s = rng.choice(OPEN) + rng.choice(SUBJECT) + " " + rng.choice(VERB) + rng.choice(TAIL) + "." + rng.choice(FOLLOW)
    return s[0].upper() + s[1:]


def generate():
    rng, seen, out = random.Random(SEED), set(), []
    while len(out) < LINES:
        s = sentence(rng)
        if s in seen or not (MIN_BYTES <= len(s.encode()) <= MAX_BYTES):
            continue
        seen.add(s)
        out.append(s)
    mean = sum(len(s.encode()) for s in out) / len(out)
    if not (MEAN_LO <= mean <= MEAN_HI):
        raise SystemExit(f"corpus mean {mean:.1f} bytes is outside [{MEAN_LO}, {MEAN_HI}]")
    return "\n".join(out) + "\n"


def main():
    text = generate()
    if sys.argv[1:] == ["--check"]:
        with open(OUT) as fh:
            sys.exit(0 if fh.read() == text else 1)
    with open(OUT, "w") as fh:
        fh.write(text)


if __name__ == "__main__":
    main()
