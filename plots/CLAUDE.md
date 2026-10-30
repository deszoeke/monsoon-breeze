# Plotting session

This directory is for interactive plotting of monsoon_convection.jl output. Start a Claude session
here for plot iteration; the repository's main session handles the model, runs and Breeze.
(`../CLAUDE.md` loads too.)

## Scope

- This session owns `plots/`: `plotter.jl`, `plots.ipynb`, `Project.toml`. Don't edit the model,
  the driver, `MonsoonConvection/`, `helpers/` or run directories.
- Physical interpretation that needs the model or Breeze source ("is this snow realistic?", "is
  this a bug?"), and any model change, go to the main session. Note plot findings worth keeping
  in `../notes/STATUS.md` when asked.
- The other session may edit `plotter.jl` too: `git pull` and re-read a file right before every edit.

## Data

- Run output lives on the cluster in `run/<name>/` (`/ceoas/deszoeks/projects/monsoon-breeze`);
  the user runs the notebook there. On the Mac, `plots/fetch_profiles.sh [run ...]` rsyncs the
  small `_profiles.nc` into the local `run/<name>/` (read-only on the cluster; scp/sftp is
  disabled on hpc, rsync and `ssh cat` work). Large files stay on the cluster.
- Files (prefix `monsoon_convection`, or `monsoon_convection_small_test`):
  - `_profiles.nc`: horizontal means averaged over each hour, (z, time), plus `radiative_flux_divergence`, `w2`;
  - `_surface.nc`: hourly lowest-level snapshots, (x, y, 1, time);
  - `_fields.nc`: 3D snapshots (x, y, z, time), daily (30 min in a small test);
  - `_checkpoint_iteration<N>.jld2`: latest state, ρ-weighted fields with halos, no grid or ρᵣ.
- Current runs: the P3 tree, `run/ekamsat-p3-ctl0` (0–2 days) and its branches `-p3-ctl2`,
  `-p3-moisten1000-850`, `-p3-moisten850-650`, `-p3-moisten650-440` (from 2 days, still
  running). See `../notes/STATUS.md` "P3 runs".
- Names in the files are ASCII. One-moment: `qv qcl qci qr qsn ql qi theta T u v w`. P3:
  `qv qcl qr nr qi ni qf bf qwi theta T u v w` (no `qci`, `qsn`; `qi` is total ice, `qf` rime,
  `bf` rime volume, `qwi` liquid on ice, `n*` numbers per kg). `condensates(p)` in
  `plotter.jl` picks the one-moment or P3 condensate panels; `qwi` and numbers aren't plotted yet.
  Mass fractions are
  kg/kg per kg of moist air (ρq/ρᵣ in the anelastic model), not mixing ratios.
- Reading the full 3D field to plot one level is ~120 MB per variable at full size; prefer
  `_surface.nc` or the profiles when they answer the question.

## Conventions in plotter.jl

- Functions read a run directory and return a Makie `Figure`; including the file only defines
  them. `save_plots(rundir)` writes PNGs for the cluster (no display). CairoMakie, theme
  `fontsize = 20`.
- Two layers. Building blocks draw into an `Axis` and return the heatmap: `time_height!(ax, p, name)`,
  `profile!`, `xz!`, `xy!` (title and labels set; the `Colorbar` and layout are the caller's).
  `plot_*` functions make a Figure from them; `compare_time_height` and `compare_profiles` put
  runs in columns and variables in rows with a shared color scale per row. New plots: write the
  `!` block first, then the figure function. Notebooks compose figures from the blocks:
  `fig = Figure(); ax = Axis(fig[1, 1]); hm = time_height!(ax, p, "qv"); Colorbar(fig[1, 2], hm)`.
- Variable names in profile plots are the file's strings ("qv", "qi", "w_rms", "qc").
- Display units: mass fractions in g/kg (`display_units`), heights in km, times in days.
- Functions of variables: every plot function has a method with `f` first, `plot_xz(f, rundir, name)`,
  applied elementwise to values in display units (`apply_finite`; non-finite → blank). In
  multi-panel plots `f` applies only to the mass-fraction panels (not anomalies, radiation, wind).
  Plain calls forward to `f = identity`.
- Behaviour by dispatch on argument types, with real keyword defaults; never branch on keyword
  values (`isnothing(kw) ? … : …`). See `time_index`, `labelled`, `color_scale`.
- Time indices: an integer or a function of the indices (`first`, `last`).
- Every function has a docstring with its signatures; keep them current. Match the comment density
  and naming of the file; small targeted edits that keep the user's changes.

## Notebook

- Two notebooks: `plot_profs.ipynb` needs only the small `_profiles.nc` files (runs on the Mac
  after `fetch_profiles.sh`); `plots.ipynb` also needs surface, 3D and checkpoint files (cluster).
  Put a new plot in the one whose files it reads.
- The notebooks hold embedded images (several MB): never Read or grep their JSON. Use
  `python3 ~/.claude/skills/notebooks/nb.py` (`outline`, `cat`, `set`, `insert`, `edit`).
- First cell: `Pkg.activate`, `using Revise; includet("plotter.jl")`, `rundir`. Figures are kept in
  variables (`fig = plot_...`) so later cells can zoom (`plot_axes(fig)[i]`, `xlims!`, `ylims!`) or
  restyle (`hm = ax.scene.plots[1]; hm.colorrange = (lo, hi)`; lo < hi).
- The user reruns cells and looks at the plots; don't rerun to verify unless asked.

## Environment

- `plots/Project.toml`: CairoMakie, NCDatasets, JLD2, Revise, Statistics, IJulia; no Breeze.
  `Pkg.instantiate()` once per machine. Never commit `Manifest.toml`.

## Working with the user

- Keep replies short: answer or act, one line of context at most; at most one offer.
- Commit and push only when asked; confirm in plain words, no commit hashes or graph-rebuild notices.
- For a substantive change (new plot or tool, a finding), ask whether to update
  `../notes/STATUS.md` (Plotting section) before suggesting a commit. Small changes: don't ask.
- Settings are Julia keyword values or assignments, never `--flag` syntax.
- Noteworthy results (numbers, comparisons, findings that go in STATUS.md or a reply) come from
  code that is saved and rerunnable: a function in `plotter.jl` or a notebook cell, reading the
  run files. Never from scratch scripts, scratchpad PNGs or numbers read off a plot. If a number
  was read off a plot, say so and add the computing cell. Write findings to STATUS.md only
  after the cell has been run, and name the cell or function there.
