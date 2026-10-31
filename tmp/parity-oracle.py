# Exact-arithmetic oracle replaying every assertion of
# ColorComposerCoreTests/SolverParityCorpusTests.swift against the committed
# fixture Fixtures/Parity/v1/corpus.json (Swift execution impossible in this
# container: no Swift toolchain; package targets macOS-only frameworks).
# Semantics mirrored 1:1 from WeightedSquaredErrorScorer + CompositionSolver.
import json, sys
LS = ["white","red","green","blue","lps"]
corpus = json.load(open(sys.argv[1]))
failures = []
def check(cond, msg):
    if not cond: failures.append(msg)
check(corpus['algorithm_version'] == 1, 'algorithm_version')
check(corpus['scorer'] == 'ColorMatching.WeightedSquaredError', 'scorer')
check(corpus['selection'] == 'earliest-index-wins', 'selection')
check(corpus['missing_policy'] == 'excluded-when-any-positive-weight-channel-missing', 'missing_policy')
check(corpus['light_sources'] == LS, 'light_sources')
check(len(corpus['scenarios']) >= 12, 'scenario count')
def cw(w): return {c: w[c] for c in LS if c in w}
def score(c, t, w):
    active = [(x, w[x]) for x in LS if x in w and w[x] > 0]
    for x, _ in active:
        if x not in c or x not in t: return 'excluded'
    s = 0.0
    for x, wt in active: s += (c[x]-t[x])**2 * wt
    return s
for sc in corpus['scenarios']:
    sid, exp = sc['id'], sc['expected']
    w = cw(sc['weights']); t = sc['target']['channels']; pal = [p['channels'] for p in sc['palette']]
    check(len(exp['scores']) == len(pal), f'{sid}: count')
    for off, e in enumerate(exp['scores']):
        check(e['index'] == off, f'{sid}: order')
        got = score(pal[off], t, w)
        check(got == e['score'] and type(got) == type(e['score']), f'{sid}[{off}] {got} != {e["score"]}')
    scored = [score(c, t, w) for c in pal]
    finite = [(i, v) for i, v in enumerate(scored) if not isinstance(v, str)]
    if exp['selected_index'] is None:
        check(not finite, f'{sid}: finite'); check(exp['tied_indices'] == [], f'{sid}: tied')
    else:
        bv = min(v for _, v in finite); bi = next(i for i, v in finite if v == bv)
        tied = [i for i, v in finite if v == bv]
        check(bi == exp['selected_index'], f'{sid}: sel'); check(bv == exp['error'], f'{sid}: err')
        check(tied == exp['tied_indices'], f'{sid}: tied'); check(exp['tie_broke'] == (len(tied) > 1), f'{sid}: tiebroke')
        check(sc['palette'][bi]['hex_color'] == exp['selected_hex_color'], f'{sid}: hex')
    active = [x for x in LS if x in w and w[x] > 0]
    if all(x in t for x in active):
        elig = [i for i, c in enumerate(pal) if all(x in c for x in active)]
        if elig:
            best = None
            for i in elig:
                v = sum((pal[i][x]-t[x])**2 * w[x] for x in active)
                if best is None or v < best[1]: best = (i, v)
            check(best[0] == exp['selected_index'] and best[1] == exp['error'], f'{sid}: solver')
        else:
            check(exp['selected_index'] is None, f'{sid}: solver none')
        check(len(pal)-len(elig) == sum(1 for e in exp['scores'] if e['score'] == 'excluded'), f'{sid}: excluded')
    else:
        check(sid == 'missing-target-excluded', f'{sid}: inexpressible')
print('FAILURES:', len(failures)); [print(' -', f) for f in failures]
sys.exit(1 if failures else 0)
