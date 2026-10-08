# Graph Report - monsoon-breeze  (2026-10-08)

## Corpus Check
- 14 files · ~14,453 words
- Verdict: corpus is large enough that graph structure adds value.
- Unclassified: 10 file(s) not represented in the graph (top: (none) 4, .toml 3, .out 1)

## Summary
- 130 nodes · 145 edges · 18 communities (14 shown, 4 thin omitted)
- Extraction: 100% EXTRACTED · 0% INFERRED · 0% AMBIGUOUS
- Token cost: 0 input · 0 output

## Graph Freshness
- Built from commit: `29d6b2e7`
- Run `git rev-parse HEAD` and compare to check if the graph is stale.
- Run `graphify update .` after code changes (no API cost).

## Community Hubs (Navigation)
- MonsoonConvection
- Monsoon convection in Breeze.jl
- monsoon_convection.jl
- P3 lookup tables stay on the CPU inside surface-flux boundary conditions → "not isbits" KernelError on GPU
- build_model
- pressure_solver_precision.jl
- Add a pressure-solver precision option to avoid unstable Float32 anelastic pressure solve on large domains
- run_workload
- check_gpu.jl
- HPC setup (GPU with CUDA, Slurm partition `ceoas-gpu`)
- build_simulation
- CM1 benchmarks
- monsoon_job.sh
- sponge_strength
- precompile_job.sh
- CLAUDE.md
- Pkg

## God Nodes (most connected - your core abstractions)
1. `MonsoonConvection` - 43 edges
2. `Monsoon convection in Breeze.jl` - 12 edges
3. `P3 lookup tables stay on the CPU inside surface-flux boundary conditions → "not isbits" KernelError on GPU` - 8 edges
4. `build_model()` - 7 edges
5. `run_workload()` - 7 edges
6. `set_initial_conditions!()` - 6 edges
7. `Changes to Breeze defaults` - 6 edges
8. `HPC setup (GPU with CUDA, Slurm partition `ceoas-gpu`)` - 6 edges
9. `interpolate_profile()` - 5 edges
10. `build_simulation()` - 5 edges

## Surprising Connections (you probably didn't know these)
- `MonsoonConvection` --defines--> `ascii_outputs()`  [EXTRACTED]
  MonsoonConvection/src/MonsoonConvection.jl → MonsoonConvection/src/MonsoonConvection.jl  _Bridges community 0 → community 10_
- `MonsoonConvection` --defines--> `build_model()`  [EXTRACTED]
  MonsoonConvection/src/MonsoonConvection.jl → MonsoonConvection/src/MonsoonConvection.jl  _Bridges community 0 → community 4_
- `MonsoonConvection` --defines--> `read_cm1_sounding()`  [EXTRACTED]
  MonsoonConvection/src/MonsoonConvection.jl → MonsoonConvection/src/MonsoonConvection.jl  _Bridges community 0 → community 7_
- `MonsoonConvection` --defines--> `sponge_strength()`  [EXTRACTED]
  MonsoonConvection/src/MonsoonConvection.jl → MonsoonConvection/src/MonsoonConvection.jl  _Bridges community 0 → community 14_
- `run_workload()` --calls--> `build_model()`  [EXTRACTED]
  MonsoonConvection/src/MonsoonConvection.jl → MonsoonConvection/src/MonsoonConvection.jl  _Bridges community 4 → community 7_

## Import Cycles
- None detected.

## Communities (18 total, 4 thin omitted)

### Community 0 - "MonsoonConvection"
Cohesion: 0.10
Nodes (16): Breeze.AtmosphereModels, Logging, Breeze, Oceananigans, Oceananigans.Architectures, Oceananigans.Grids, Oceananigans.TimeSteppers, Oceananigans.Units (+8 more)

### Community 1 - "Monsoon convection in Breeze.jl"
Cohesion: 0.10
Nodes (19): 1. TKE closure: eddy diffusivities capped at 100 m² s⁻¹ (safeguard; physics change only when active), 2. P3 microphysics built on the target architecture (bug workaround, no physics change), 3. Float64 pressure solve (numerical precision), 4. Bounded (positivity-preserving) WENO scalar advection, Changes to Breeze defaults, Compile-run strategy, Files, Glossary (+11 more)

### Community 2 - "monsoon_convection.jl"
Cohesion: 0.18
Nodes (6): MonsoonConvection, Oceananigans, Oceananigans.Grids, Oceananigans.Units, Printf, Oceananigans.Advection

### Community 3 - "P3 lookup tables stay on the CPU inside surface-flux boundary conditions → "not isbits" KernelError on GPU"
Cohesion: 0.22
Nodes (8): Cause, Error (excerpt), Minimal example, P3 lookup tables stay on the CPU inside surface-flux boundary conditions → "not isbits" KernelError on GPU, Suggested fix, Summary, Versions, Workaround

### Community 4 - "build_model"
Cohesion: 0.46
Nodes (8): build_model(), interpolate_profile(), q̄ᵗ(), scalar_bounds(), set_initial_conditions!(), v̄(), ū(), θ̄()

### Community 5 - "pressure_solver_precision.jl"
Cohesion: 0.29
Nodes (6): Breeze.AnelasticEquations, Breeze, Oceananigans, Oceananigans.Architectures, Oceananigans.Grids, Oceananigans.Solvers

### Community 6 - "Add a pressure-solver precision option to avoid unstable Float32 anelastic pressure solve on large domains"
Cohesion: 0.29
Nodes (6): Add a pressure-solver precision option to avoid unstable Float32 anelastic pressure solve on large domains, Crashing pressure solver with Float32, MWE setup, Suggestion, Summary, Versions

### Community 7 - "run_workload"
Cohesion: 0.29
Nodes (6): read_cm1_sounding(), restore_latest_checkpoint!(), run_simulation!(), run_workload(), Sounding, workload_sounding()

### Community 8 - "check_gpu.jl"
Cohesion: 0.33
Nodes (4): MonsoonConvection, Oceananigans, Oceananigans.TimeSteppers, Printf

### Community 9 - "HPC setup (GPU with CUDA, Slurm partition `ceoas-gpu`)"
Cohesion: 0.33
Nodes (6): 0. Inspect the partition (once), 1. Environment and Julia depot (login node), 2. Set up and check a GPU node (interactive), 3. Measure throughput (interactive, optional), 4. Production runs (batch), HPC setup (GPU with CUDA, Slurm partition `ceoas-gpu`)

### Community 10 - "build_simulation"
Cohesion: 0.40
Nodes (5): ascii_outputs(), build_simulation(), microphysics_outputs(), netcdf_attributes(), netcdf_name()

### Community 11 - "CM1 benchmarks"
Cohesion: 0.50
Nodes (3): CM1 benchmarks, MPI test 1 - amaterasu, OpenMP

### Community 13 - "monsoon_job.sh"
Cohesion: 0.50
Nodes (3): CUDA_VISIBLE_DEVICES, PATH, monsoon_job.sh script

### Community 14 - "sponge_strength"
Cohesion: 0.50
Nodes (4): sponge_strength(), sponge_ρu(), sponge_ρv(), sponge_ρθ()

## Knowledge Gaps
- **71 isolated node(s):** `Breeze`, `Oceananigans`, `Oceananigans.Units`, `Oceananigans.Grids`, `Oceananigans.TimeSteppers` (+66 more)
  These have ≤1 connection - possible missing edges or undocumented components. (Counts symbols only; 91 node(s) total have ≤1 connection when file, concept and rationale nodes are included.)
- **4 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `MonsoonConvection` connect `MonsoonConvection` to `build_simulation`, `build_model`, `sponge_strength`, `run_workload`?**
  _High betweenness centrality (0.108) - this node is a cross-community bridge._
- **What connects `Breeze`, `Oceananigans`, `Oceananigans.Units` to the rest of the system?**
  _71 weakly-connected nodes found - possible documentation gaps or missing edges._
- **Should `MonsoonConvection` be split into smaller, more focused modules?**
  _Cohesion score 0.09523809523809523 - nodes in this community are weakly interconnected._
- **Why does `Monsoon convection in Breeze.jl` connect `Monsoon convection in Breeze.jl` to `HPC setup (GPU with CUDA, Slurm partition `ceoas-gpu`)`?**
  _High betweenness centrality (0.032) - this node is a cross-community bridge._
- **Should `Monsoon convection in Breeze.jl` be split into smaller, more focused modules?**
  _Cohesion score 0.1 - nodes in this community are weakly interconnected._