#!/usr/bin/env python3
"""Exact IEEE-754 replication of WeightedSquaredErrorScorer + earliest-wins
selection, run against the committed parity corpus fixture.

Purpose: the container running the test-writing phase has no Swift toolchain,
so this script reproduces the committed SolverParityCorpusTests assertions
one-for-one (same canonical channel order white,red,green,blue,lps as
ChannelWeights.activeEntries; same candidate/target exclusion rule; same
strict earliest-wins argmin) and compares with exact double equality, which
is what the Swift test asserts (accuracy 1e-12 over exactly-representable
dyadic values).

Run:  python3 tmp/parity-replication.py
"""
import json
import os
import sys

ORDER = ["white", "red", "green", "blue", "lps"]  # LightingCondition.all / activeEntries order


def wse(cand, target, weights):
    for ch in ORDER:
        w = weights.get(ch, 0.0)
        if w > 0 and (ch not in cand or ch not in target):
            return None  # excluded
    s = 0.0
    for ch in ORDER:
        w = weights.get(ch, 0.0)
        if w > 0:
            diff = cand.get(ch, 0.0) - target.get(ch, 0.0)
            s += diff * diff * w
    return s


def main(path):
    with open(path) as f:
        d = json.load(f)
    assert d["algorithm_version"] == 1
    assert d["scorer"] == "ColorMatching.WeightedSquaredError"
    assert d["selection"] == "earliest-index-wins"
    assert d["missing_policy"] == "excluded-when-any-positive-weight-channel-missing"

    failures = 0
    for sc in d["scenarios"]:
        # Unknown light-source keys dropped exactly like LightingCondition(rawValue:)
        weights = {k: v for k, v in sc["weights"].items() if k in ORDER}
        scores = [wse(p["channels"], sc["target"]["channels"], weights) for p in sc["palette"]]

        # Palette vector index == position (corpus invariant asserted by the Swift test)
        for pos, vec in enumerate(sc["palette"]):
            assert vec["index"] == pos, (sc["id"], pos)

        e = sc["expected"]
        norm = lambda x: None if x == "excluded" else x
        for i, (got, exp) in enumerate(zip(scores, [norm(x["score"]) for x in e["scores"]])):
            if got != exp:  # exact double comparison
                print(f"FAIL {sc['id']}[{i}]: got {got} expected {exp}")
                failures += 1

        finite = [(i, s) for i, s in enumerate(scores) if s is not None]
        if finite:
            best = min(s for _, s in finite)
            tied = [i for i, s in finite if s == best]
            sel, tie_broke, err = tied[0], len(tied) > 1, best
        else:
            sel, tied, tie_broke, err = None, [], None, None

        def check(label, got, exp):
            nonlocal failures
            if got != exp:
                print(f"FAIL {sc['id']} {label}: got {got!r} expected {exp!r}")
                failures += 1

        check("selected_index", sel, e["selected_index"])
        check("tied_indices", tied, e["tied_indices"])
        check("tie_broke", tie_broke, e["tie_broke"])
        check("error", err, e["error"])
        if sel is not None:
            check("selected_hex", sc["palette"][sel]["hex_color"], e["selected_hex_color"])

    print(f"scenarios={len(d['scenarios'])} assertion_failures={failures}")
    return 0 if failures == 0 else 1


if __name__ == "__main__":
    corpus = sys.argv[1] if len(sys.argv) > 1 else os.path.join(
        os.path.dirname(__file__), "..",
        "ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/parity/v1/corpus.json",
    )
    sys.exit(main(corpus))
