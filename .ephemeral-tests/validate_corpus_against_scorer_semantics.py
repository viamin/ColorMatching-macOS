#!/usr/bin/env python3
"""PR-only one-off verification for issue #39 (remove before merge).

Replays the committed parity corpus against a line-for-line Python replica
of ColorComposerCore's WeightedSquaredErrorScorer + CompositionSolver
semantics (IEEE 754 doubles, canonical channel order white/red/green/blue/lps,
strict less-than keeps the earliest tied candidate, unknown weight keys
ignored). This validates the corpus <-> Swift-semantics relationship on
hosts without a Swift toolchain; the authoritative check is
SolverParityCorpusTests.swift.
"""

import json
import os
import sys

SOURCES = ["white", "red", "green", "blue", "lps"]

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FIXTURE = os.path.join(
    ROOT,
    "ColorComposerCore", "Tests", "ColorComposerCoreTests",
    "Fixtures", "parity", "v1", "corpus.json",
)


def scorer_score(candidate, target, weights):
    active = [(s, weights.get(s, 0.0)) for s in SOURCES if weights.get(s, 0.0) > 0]
    for source, _ in active:
        if source not in candidate or source not in target:
            return None  # .excluded
    total = 0.0
    for source, weight in active:
        diff = candidate[source] - target[source]
        total += diff * diff * weight
    return total


def solver_selection(palette, target, weights):
    active = [s for s in SOURCES if weights.get(s, 0.0) > 0]
    if any(s not in target for s in active):
        return "unbuildable"  # BrightnessGrid cannot express a missing target channel
    best_error, best_index = float("inf"), None
    for index, candidate in enumerate(palette):
        if any(s not in candidate for s in active):
            continue  # excluded: not eligible
        total = 0.0
        for source in active:
            diff = candidate[source] - target[source]
            total += diff * diff * weights[source]
        if total < best_error:  # strict: earliest tied candidate wins
            best_error, best_index = total, index
    return best_index, best_error


def main():
    with open(FIXTURE) as handle:
        corpus = json.load(handle)

    assert corpus["algorithm_version"] == 1, "corpus algorithm_version moved"
    assert corpus["scorer"] == "ColorMatching.WeightedSquaredError"
    assert corpus["selection"] == "earliest-index-wins"
    assert corpus["light_sources"] == SOURCES

    failures = []
    for scenario in corpus["scenarios"]:
        sid = scenario["id"]
        weights, target, palette, expected = (
            scenario["weights"],
            scenario["target"]["channels"],
            [entry["channels"] for entry in scenario["palette"]],
            scenario["expected"],
        )

        for entry in expected["scores"]:
            want = entry["score"]
            got = scorer_score(palette[entry["index"]], target, weights)
            if want == "excluded":
                if got is not None:
                    failures.append(f"{sid} score[{entry['index']}]: expected excluded, got {got!r}")
            elif got != want:
                failures.append(f"{sid} score[{entry['index']}]: expected {want!r}, got {got!r}")

        selection = solver_selection(palette, target, weights)
        if selection == "unbuildable":
            if expected["selected_index"] is not None:
                failures.append(f"{sid}: expected no selection for unbuildable target")
            continue
        selected, error = selection
        if selected != expected["selected_index"]:
            failures.append(f"{sid}: selection want {expected['selected_index']}, got {selected}")
        if selected is not None and error != expected["error"]:
            failures.append(f"{sid}: error want {expected['error']!r}, got {error!r}")

        ranked = [e for e in expected["scores"] if e["score"] != "excluded"]
        if ranked:
            minimum = min(e["score"] for e in ranked)
            tied = [e["index"] for e in ranked if e["score"] == minimum]
            if tied != expected["tied_indices"]:
                failures.append(f"{sid}: tied want {expected['tied_indices']}, got {tied}")
            if tied and tied[0] != expected["selected_index"]:
                failures.append(f"{sid}: earliest tied index must win")

    if failures:
        print(f"FAIL: {len(failures)} parity mismatches")
        for failure in failures:
            print("  -", failure)
        return 1
    print(f"PASS: {len(corpus['scenarios'])} corpus scenarios reproduce scorer, "
          "selection, tie, and exclusion semantics exactly")
    return 0


if __name__ == "__main__":
    sys.exit(main())
