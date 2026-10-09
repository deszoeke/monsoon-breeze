## Picking up the work

Start with `notes/STATUS.md` (current state, runs, next steps). Keep it current: update it and
`notes/nan_investigation.md` when a run finishes or a hypothesis is tested.

## Code analysis
Use graphify for code analysis. This repo is small (~1k lines); most of the relevant code is in
Breeze and Oceananigans. Run `helpers/graph_package.sh` first (~1 s; it rebuilds a graph only if that
package's source changed), then query `--graph graphify-breeze/graphify-out/graph.json` or
`--graph graphify-oceananigans/graphify-out/graph.json`. Grep only to read specific lines.

## graphify

This project has a knowledge graph at graphify-out/ with god nodes, community structure, and cross-file relationships.

Rules:
- For codebase questions, first run `graphify query "<question>"` when graphify-out/graph.json exists. Use `graphify path "<A>" "<B>"` for relationships and `graphify explain "<concept>"` for focused concepts. These return a scoped subgraph, usually much smaller than GRAPH_REPORT.md or raw grep output.
- If graphify-out/wiki/index.md exists, use it for broad navigation instead of raw source browsing.
- Read graphify-out/GRAPH_REPORT.md only for broad architecture review or when query/path/explain do not surface enough context.
- After modifying code, run `graphify update .` to keep the graph current (AST-only, no API cost).
