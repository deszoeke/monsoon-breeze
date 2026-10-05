# Breeze.jl translation of the CM1 (r21.1) case in ./cm1:
#
#   ASdry4800-7200 — EKAMSAT Arabian Sea monsoon convection, 17 June 2023 sounding,
#   simplified with a dry (qv = 0.3 g/kg) layer at 4800–7200 m and -8 m/s low-level shear.
#   Adapted from the CM1 cpm_RadConvEquil case (Bretherton et al. 2005).
#
# CM1 namelist → Breeze mapping
#
#   nx, ny, nz = 1024, 512, 65; dx = dy = 500 m      → RectilinearGrid, 512 km × 256 km
#   stretch_z = 1 (50 m → 500 m by 5 km), ztop 28 km  → explicit z faces (identical to CM1 zf)
#   wbc = ebc = sbc = nbc = 1                          → Periodic × Periodic
#   psolver = 3 (compressible)                         → AnelasticDynamics
#   hadvord/vadvord = 5, weno_order = 5                → WENO(order=5)
#   ptype = 5 (Morrison 2-moment w/ ice)               → P3 microphysics (Morrison & Milbrandt
#                                                        successor; 2-moment rain and ice)
#   ipbl = 2, sgsmodel = 0, horizturb = 0              → vertical-only TKE closure
#   sfcmodel = 1, oceanmodel = 1, tsk0 = 301 K         → bulk fluxes over fixed 301 K SST
#   radopt = 2 (RRTMG), dtrad = 300 s, perpetual sun   → RRTMGP all-sky, fixed cos(zenith),
#      (solcon = 650.83 W/m², coszen = 0.636,             updated every 300 s
#       albedo = 0.08, CO₂ = 387.75 ppm, from cm1.print.out)
#   icor = 1, fcor = 2.5325e-5 (10°N)                  → FPlane(f = 2.5325e-5)
#   lspgrad = 1                                        → geostrophic forcing f × u_g(z)
#                                                        balancing the initial wind
#   irdamp = 2, zd = 20 km, rdalpha = 1/300 s          → Rayleigh relaxation of ρw, sin² ramp
#   isnd = 7 (input_sounding), irandp = 1              → sounding interpolated in z,
#                                                        ±0.25 K random θ perturbations
#   timax = 345700 s, statfrq = 3600 s,                → stop_time, hourly mean profiles,
#   tapfrq = rstfrq = 86400 s                            daily 3D output and checkpoints
#
# Not translated: apmasscon, kdiv/alph acoustic damping (compressible-only), CM1's
# pressure-dependent microphysics options (nssl2mom_params are unused for ptype = 5).
#
# ──────────────────────────────────────────────────────────────────────────────────────
# Usage
#
#   julia --project monsoon_convection.jl [flags]
#
#   --arch=cpu|gpu        hardware to run on (default cpu). A gpu request is checked
#                         (NVIDIA device, CUDA working) before any package is loaded, and
#                         the run halts if the GPU is unavailable.
#   --float=Float32|Float64
#                         floating-point precision (default Float32 on gpu, Float64 on cpu).
#                         Single precision is standard for GPU runs of this kind.
#   --small_test          32×16 columns (16 km × 8 km), 1 h: a quick check that the code
#                         runs, not a scientific configuration.
#   --restart             continue from the latest checkpoint in the current directory.
#                         Output is appended to the existing NetCDF files.
#   --stop_time=96h       TOTAL simulated time (units d, h, min, s), counted from the start
#                         of the original run, also when restarting. Default: CM1 timax =
#                         345700 s (≈ 96 h), or 1 h with --small_test.
#   --wall_time=47h       real (wall-clock) time limit for this job. The run stops cleanly
#                         and writes a checkpoint; continue it with --restart. Set it a
#                         little below the batch job's time limit. Default: none.
#
# Examples
#   julia --project monsoon_convection.jl --small_test
#   julia --project monsoon_convection.jl --small_test --restart --stop_time=1.5h
#   julia --project monsoon_convection.jl --arch=gpu --wall_time=47h
#   julia --project monsoon_convection.jl --arch=gpu --restart --wall_time=47h
#
# Run directory: output (NetCDF) and checkpoints (JLD2) are written to the directory you
# launch from, and --restart looks for checkpoints there. Use one run directory per
# experiment, on a scratch filesystem on HPC.
#
# Output
#   <prefix>_profiles.nc     hourly horizontal means (time-averaged over each hour)
#   <prefix>_surface.nc      hourly snapshots at the lowest model level (z = 25 m)
#   <prefix>_fields.nc       3D snapshots, daily (every 30 min with --small_test)
#   <prefix>_checkpoint_iteration<N>.jld2   restart file; only the latest is kept
# Variables: u, v, w (m/s), theta (liquid-ice potential temperature, K), T (K),
# qv (specific humidity, kg/kg), P3 microphysics mass fractions qcl, qr, qi, qf, qwi
# (kg/kg), numbers nr, ni (per kg of air) and rime volume bf (m3/kg). Each variable
# carries units and long_name attributes.
#
# Compilation: the model code lives in the precompiled package ./MonsoonConvection
# (see README.md). One-time setup, and again after package updates or package edits:
#     julia --project setup_precompile.jl --arch=cpu    # or --arch=gpu, on a GPU node
# Editing this driver never triggers recompilation:
#   free to change: the sounding (values and number of levels), initial conditions,
#                   grid size, keyword values of build_model/build_simulation, flags
#   recompiles:     editing MonsoonConvection, changing the microphysics or closure type,
#                   setup_precompile.jl with a different --arch, a new CPU type
# ──────────────────────────────────────────────────────────────────────────────────────

include(joinpath(@__DIR__, "preflight.jl"))

# Validate every flag, and check the requested hardware, before loading any package
# (and its compile cache), so that mistakes fail in seconds with a short message.
settings = try
    flags = parse_flags(ARGS, ("arch", "float", "small_test", "restart", "stop_time", "wall_time"))

    small_test = parse_bool("small_test", get(flags, "small_test", "false"))
    restart    = parse_bool("restart", get(flags, "restart", "false"))

    stop_time = haskey(flags, "stop_time") ? parse_duration("stop_time", flags["stop_time"]) :
                small_test ? 3600.0 : 345700.0                  # seconds; CM1 timax
    wall_time_limit = haskey(flags, "wall_time") ? parse_duration("wall_time", flags["wall_time"]) : Inf

    arch_request = lowercase(get(flags, "arch", "cpu"))
    float_type = get(flags, "float", arch_request == "gpu" ? "Float32" : "Float64")
    float_type in ("Float32", "Float64") || error("--float must be Float32 or Float64, got \"$float_type\"")

    check_requested_architecture(arch_request)

    (; small_test, restart, stop_time, wall_time_limit, arch_request, float_type)
catch err
    println(stderr, "ERROR: ", sprint(showerror, err))
    println(stderr, "Usage: see the header of monsoon_convection.jl")
    exit(1)
end

(; small_test, restart, stop_time, wall_time_limit, arch_request, float_type) = settings

using Oceananigans
using Oceananigans.Units

Oceananigans.defaults.FloatType = float_type == "Float32" ? Float32 : Float64

using MonsoonConvection

arch = arch_request == "gpu" ? GPU() : CPU()

#####
##### Experiment: sounding and grid
#####

# CM1 input_sounding (isnd = 7). For a new experiment, point to another file, or build
# a Sounding(p₀, z, θ, r, u, v) from vectors (r is the vapor mixing ratio in kg/kg).
sounding = read_cm1_sounding(joinpath(@__DIR__, "cm1", "input_sounding"))

# ---- Analytic sounding from anonymous functions -------------------------------------
# Write the profiles here as anonymous functions of height z (m) and *evaluate* them on a
# vector of heights. Only the resulting Vector{Float64}s reach MonsoonConvection, so any
# functions, any number of levels and any values reuse the precompiled code. (Passing the
# functions themselves into the package would create new types and trigger compilation.)
#
# z  = collect(0.0:100.0:40000.0)                        # heights (m), increasing
# θ  = z -> 300 + 4e-3 * z + 12 * max(0, z - 15000) / 1000  # potential temperature (K)
# r  = z -> 0.018 * exp(-z / 2500)                        # vapor mixing ratio (kg/kg)
# u  = z -> -5 * clamp(1 - z / 3000, 0, 1)                # zonal wind (m/s)
# v  = z -> 0.0                                           # meridional wind (m/s)
# sounding = Sounding(101000.0, z, θ.(z), r.(z), u.(z), v.(z))  # p₀ = surface pressure (Pa)
#
# The same Sounding also sets the anelastic reference state and the geostrophic wind
# (CM1 lspgrad = 1), so keep it consistent with the initial conditions below.
# --------------------------------------------------------------------------------------

Nx, Ny = small_test ? (32, 16) : (1024, 512)

# Grid and physical parameters are keyword *values* of build_model (defaults are the CM1
# namelist; see "Model" in MonsoonConvection/src/MonsoonConvection.jl), so they can be
# changed here without recompiling, e.g.
#     build_model(sounding; arch, Nx, Ny, Δx = 250, z_faces = collect(0.0:250.0:28000.0),
#                 sea_surface_temperature = 302, CO₂ = 420e-6, sponge_bottom = 18000)
# Pass z_faces as a Vector{Float64} (collect a range): a range is a different type and would
# compile a different grid.
model = build_model(sounding; arch, Nx, Ny)

#####
##### Initial conditions (CM1 irandp = 1: ±0.25 K random θ perturbations)
#####
#
# Custom initial conditions: replace the line below with anonymous functions of (x, y, z)
# passed to set! (only a small set! kernel compiles at run time, < 1 s). Note the variables
# set! expects:
#   θ   liquid-ice potential temperature (K); equals θ while the air is unsaturated
#   qᵗ  total-water SPECIFIC HUMIDITY (kg/kg), qᵗ = r / (1 + r), not the mixing ratio r
#   u, v (m/s)
# Example, a warm bubble on top of the sounding:
#
#     using MonsoonConvection: θ̄, q̄ᵗ, ū, v̄   # sounding interpolants, called as θ̄(sounding, z)
#     restart || set!(model; θ  = (x, y, z) -> θ̄(sounding, z) + 2exp(-((x - 8e3)^2 + (z - 1e3)^2) / 1e6),
#                           qᵗ = (x, y, z) -> q̄ᵗ(sounding, z),
#                           u  = (x, y, z) -> ū(sounding, z),
#                           v  = (x, y, z) -> v̄(sounding, z))

restart || set_initial_conditions!(model, sounding; δθ = 0.25, seed = 2023)

#####
##### Run (CM1 timax = 345700 s)
#####

prefix = small_test ? "monsoon_convection_small_test" : "monsoon_convection"
simulation = build_simulation(model; stop_time, wall_time_limit, small_test, restart, prefix)

@info "Monsoon convection: $(Nx)×$(Ny)×$(size(model.grid, 3)) on $(arch) in $(Oceananigans.defaults.FloatType), " *
      "stop time $(prettytime(stop_time)), wall-time limit $(isinf(wall_time_limit) ? "none" : prettytime(wall_time_limit))"

restart && restore_latest_checkpoint!(simulation)

run_simulation!(simulation)
