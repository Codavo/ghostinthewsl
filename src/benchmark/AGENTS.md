# Benchmarking

The benchmark tools are split into two roles:

- `ghostty-gen` generates synthetic input data.
- `ghostty-bench` consumes existing input data and runs a benchmark.

## Workflow

- For timing comparisons, generate data first and benchmark it later.
- Do not pipe `ghostty-gen` directly into `ghostty-bench` when comparing
  performance. That mixes generation cost into the measurement and makes
  branch-to-branch comparisons noisy.
- Reuse the exact same generated files when comparing revisions.
- Prefer deterministic generation inputs such as fixed seeds when the
  generator supports them.
- Keep large generated benchmark corpora outside the repository unless the
  change explicitly requires checked-in test data.

## Running Benchmarks

- Prefer `hyperfine` to compare benchmark timings.
- Benchmark the `ghostty-bench` command line, not the generator.
- Use `ghostty-bench ... --data <path>` with pre-generated files.
- Run multiple warmups and repeated measurements so branch comparisons are
  based on medians instead of single runs.
- When comparing branches, keep all benchmark inputs and CLI flags the same,
  including terminal dimensions.

## Building

- Build benchmark tools with `zig build -Demit-bench`.
- On macOS, prefer `zig build -Demit-bench -Demit-macos-app=false` unless the
  macOS app itself is part of the work.
