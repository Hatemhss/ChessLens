# Local position reconciliation benchmark

Recorded 2026-09-27 on Apple M3 Pro, arm64, macOS 26.5.2.
Compiler: Apple Swift 6.3.3 (swiftlang-6.3.3.1.3), SwiftPM release configuration.

The same opt-in test was run immediately before and after the changes to
`Sources/ChessLens/PositionReconciler.swift`:

```sh
env CHESSLENS_BENCHMARK=1 \
  CLANG_MODULE_CACHE_PATH=/Users/hatem/solveC/.build/ModuleCache \
  SWIFTPM_MODULECACHE_OVERRIDE=/Users/hatem/solveC/.build/ModuleCache \
  swift test -c release --disable-sandbox \
  --filter PositionReconcilerTests/testReconciliationReleaseBenchmark
```

Each workload uses 35 calls: five warm-ups followed by 30 timed samples.
The fixed input is the original `fast-pawn-reply.png` test fixture, cropped at
`CGRect(x: 51, y: 107, width: 1171, height: 1172)`. The starting baseline restores
e2/e7 pawn appearances and e4/e5 empty appearances from other squares in the same
image. Only the final e4/e5 position is supplied to the reconciler. Every run
asserts that the returned move count is correct.

| Workload | Before median | Before p95 | After median | After p95 |
| --- | ---: | ---: | ---: | ---: |
| Final board after e4/e5, no intermediate capture | 13.8795 ms | 14.3922 ms | 4.8138 ms | 4.8515 ms |
| Exact unchanged observation | 13.4619 ms | 14.5927 ms | 0.000417 ms | 0.000417 ms |

The two-ply workload improved by approximately **2.88×**. This measures only local
reconciliation: it excludes screen capture, appearance extraction, stability
waiting, and Stockfish analysis. It is not an end-to-end application speed claim.
The unchanged workload reuses the same observation buffers, exercising the exact
equality fast path; independently captured identical images may incur additional
array comparisons.

Changes measured:

- Remove exactly duplicate appearance references, without merging similar pieces.
- Stop comparing a reference once its partial squared error cannot beat the best
  complete reference match; retain the original distance arithmetic.
- Use direct numeric piece labels instead of per-square string conversions.
- Return unchanged when the observed appearance exactly equals the confirmed baseline.
- Avoid a temporary distance array in motion comparison.

All candidate acceptance thresholds and legal-move/ambiguity checks remain intact.
The independent `maximumPlies: 0` bug was also fixed: it no longer searches one move.

Regression validation: 13 reconciliation tests passed, with the opt-in benchmark
skipped by the normal test run. Coverage includes the original screenshot, all
20 legal opening moves followed by e7/e5 with noisy appearance vectors, fresh
unchanged buffers, castling, en passant, captures, illegal/ambiguous observations,
and zero/one-ply limits.
