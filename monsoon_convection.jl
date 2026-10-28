# Breeze.jl translation of the CM1 (r21.1) case in ./cm1:
#
#   ASdry4800-7200 — EKAMSAT Arabian Sea monsoon convection, 17 June 2023 sounding,
#   simplified with a dry (qv = 0.3 g/kg) layer at 4800–7200 m and -8 m/s low-level shear.
#   Adapted from the CM1 cpm_RadConvEquil case (Bretherton et al. 2005).
#
# CM1 namelist → Breeze mapping
#
#   nx, ny, nz = 1024, 512, 65; dx = dy = 500 m      → RectilinearGrid, 512 km × 256 km
#   stretch_z = 1 (50 m → 500 m by 5 km), ztop 28 km  → CM1 zf up to 18 km; above, Δz stretches
#                                                        to ~1 km at 28 km (MODIFIED; see "Vertical grid")
#   wbc = ebc = sbc = nbc = 1                          → Periodic × Periodic
#   psolver = 3 (compressible)                         → AnelasticDynamics
#   hadvord/vadvord = 5, weno_order = 5                → WENO(order=5)
#   ptype = 5 (Morrison 2-moment w/ ice)               → mixed-phase one-moment microphysics
#                                                        (MODIFIED; microphysics = :p3 for P3, the
#                                                        Morrison & Milbrandt successor)
#   ipbl = 2, sgsmodel = 0, horizturb = 0              → vertical-only TKE closure, diffusivities
#      (l_inf = 75 m)                                    capped at maximum_diffusivity = 100 m²/s
#                                                        (MODIFIED from Breeze's default: no cap;
#                                                        see README, "Changes to Breeze defaults")
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
# Running
#
# Each experiment has its own run directory holding its own copy of this file: edit the settings
# below in that copy. A queued job reads the copy when it starts, so editing the repository's
# file never changes a submitted run, and the run directory keeps the code that ran.
#
#   mkdir -p run/exp && cp monsoon_convection.jl run/exp/     # new experiment; edit its settings
#   sbatch -p ceoas-arm --gres=gpu:gh200_480gb:1 monsoon_job.sh run/exp   # see monsoon_job.sh
#   # to continue: set restart = true in run/exp/monsoon_convection.jl and submit again
#
#   cd run/exp && julia --project=../.. monsoon_convection.jl   # interactive or local run
#
# Output (NetCDF) and checkpoints (JLD2) go to the directory Julia runs in.
#   <prefix>_profiles.nc     hourly horizontal means (time-averaged over each hour)
#   <prefix>_surface.nc      hourly snapshots at the lowest model level (z = 25 m)
#   <prefix>_fields.nc       3D snapshots, daily (every 30 min with small_test)
#   <prefix>_checkpoint_iteration<N>.jld2   restart file; only the latest is kept
# Variables: u, v, w (m/s), theta (liquid-ice potential temperature, K), T (K),
# qv (specific humidity, kg/kg) and the microphysics fields: one-moment mass fractions qcl, qci,
# qr, qsn and totals ql, qi (kg/kg); P3 mass fractions qcl, qr, qi, qf, qwi (kg/kg), numbers nr, ni
# (per kg of air) and rime volume bf (m3/kg). Each variable carries units and long_name attributes.
#
# Compilation: the model code lives in the precompiled package ./MonsoonConvection
# (see README.md). One-time setup, and again after package updates or package edits:
#     julia --project setup_precompile.jl     # on HPC: sbatch -p <partition> precompile_job.sh
#     julia --project check_gpu.jl            # on a GPU node: checks the model runs on the GPU
# GPU runs compile their GPU-specific code at startup (a few minutes). None of the settings below,
# nor the sounding, grid size or initial conditions, recompiles MonsoonConvection.
# ──────────────────────────────────────────────────────────────────────────────────────

using Oceananigans.Units: second, seconds, minute, minutes, hour, hours, day, days

#####
##### Settings
#####

# Run
arch                    = :gpu         # :gpu | :cpu. :gpu stops at once unless CUDA works.
small_test              = false        # true: 32×16 columns (16 × 8 km), 1 h; a code check only
restart                 = true         # true: continue from the latest checkpoint in this directory,
                                       # appending to the NetCDF output
stop_time               = small_test ? 1hour : 7days  # TOTAL simulated time, counted from
                                       # the original start also when restarting (CM1 timax)
checkpoint_interval     = small_test ? 30minutes : 1hour  # model time between restart files. None
                                       # is written on NaN; only the latest is kept
debug_nan               = false        # every 10 iterations print field extremes and each bounds
                                       # violation's location; stop at the first NaN/Inf

# Model
float_type              = Float32      # model precision: Float32 (standard on GPUs) | Float64
microphysics            = :one_moment  # :one_moment, Breeze's mixed-phase scheme (cloud liquid,
                                       # cloud ice, rain, snow) | :p3, closest to CM1 ptype = 5
                                       # but not production ready; compiles at startup
sponge_variables        = :w           # upper sponge above 20 km: :w damps w only (CM1 irdamp = 2)
                                       # | :all also relaxes u, v, θ to the sounding (irdamp = 1)
sponge_timescale        = 300seconds   # damping time scale at the top (CM1 rdalpha = 1/300 s)
geostrophic_bottom_pressure = 900      # hPa: the wind is geostrophic above; below, the geostrophic
                                       # wind (pressure gradient) is held at its 900 hPa value
sst_offset              = 1            # K: SST = lowest air temperature of the sounding + sst_offset

# Experiment: external vapor source, constant and horizontally uniform, vapor only (no heating).
# The control spins up for 2 days with no source; each experiment restarts from a copy of its
# 2-day checkpoint with a source in one layer: (1000, 850), (850, 650) or (650, 440) hPa.
vapor_source_rate       = 0.0          # kg/kg/day; 0 for the control
vapor_source_layer      = (850, 650)   # (bottom, top) pressures, hPa

# Fixes to Breeze. Keep them on.
pressure_solver_type    = Float64      # Float32 is unstable on the full 512 km domain (README);
                                       # Float64 with a Float32 model is ~2× faster than all-Float64
implicit_rain_sink      = microphysics == :one_moment  # backward-Euler rain–snow collection
                                       # sinks, which otherwise drive rain and snow negative
                                       # (helpers/implicit_rain_sink_correction.jl; one-moment only)

# Stability options: on in every tested run; not yet tested off with the fixes above
sedimentation_cfl       = false        # the time step also keeps |w + w_fall| Δt / Δz ≤ cfl
                                       # (Breeze's limit uses u, v, w only)
bounded_advection       = false        # bounds-preserving WENO for scalars (moisture, hydrometeors,
                                       # numbers ≥ 0); false: plain WENO(5)

#####
##### Setup
#####

# The repository (helpers/, cm1/): the project this runs in, wherever this copy of the file is
repo = dirname(Base.active_project())
include(joinpath(repo, "helpers", "preflight.jl"))
arch == :gpu && require_gpu()

# Stop and checkpoint 10 min before a Slurm job's time limit; no limit outside Slurm
wall_time_limit = haskey(ENV, "SLURM_JOB_END_TIME") ?
                  parse(Int, ENV["SLURM_JOB_END_TIME"]) - time() - 10minutes : Inf

using Oceananigans

Oceananigans.defaults.FloatType = float_type

using MonsoonConvection

# The manifest is not tracked, so record the package versions in the run's log.
@info "Julia $(VERSION), Breeze $(pkgversion(MonsoonConvection.Breeze)), Oceananigans $(pkgversion(Oceananigans)), " *
      "CloudMicrophysics $(pkgversion(MonsoonConvection.CloudMicrophysics))"

# Pressure-solve precision different from the model's. A Breeze with
# AnelasticDynamics(...; pressure_solver_float_type) (our PR) does it itself; for the registered
# Breeze 0.12, override its solver construction for this session (helpers/pressure_solver_precision.jl).
breeze_solver_precision = hasfield(MonsoonConvection.Breeze.AnelasticDynamics, :pressure_solver_float_type)
if !breeze_solver_precision && pressure_solver_type != float_type
    include(joinpath(repo, "helpers", "pressure_solver_precision.jl"))
    Base.invokelatest(() -> (Main.pressure_solver_float_type[] = pressure_solver_type))
end

hardware = arch == :gpu ? GPU() : CPU()

#####
##### Experiment: sounding and grid
#####

# EKAMSAT sounding experiments (helpers/ekamsat_soundings.jl, cm1/soundings/README.md): start from the
# control, the observed sounding, and apply the changes that make the experiment.
#
#     control                                           (CM1 AS20230617)
#     └─ exp1  interp_1200_7200                         (AS12007200)
#        └─ restore_4800m_level
#           ├─ shear_set_4800m_u(u = −8, −7.2, −0.4)    (ASu4800-8, ASu4800-7p2, ASu4800-p4)
#           └─ dry_layer(0.3 g/kg, 4800–7200 m)         (ASdry4800-7200)
#              └─ shear_set_4800m_u(u = −8)             (ASdryu4800-8)
#
# For another sounding, read a CM1 file with read_cm1_sounding(path), or build a
# Sounding(p₀, z, θ, r, u, v) from vectors (r is the vapor mixing ratio in kg/kg).
#
# include(joinpath(repo, "helpers", "ekamsat_soundings.jl"))
# control = ekamsat_control()
# exp1    = interp_1200_7200(control)
# dry     = dry_layer(restore_4800m_level(exp1), 0.3, (4800.0, 7200.0))
# sounding = ekamsat_sounding(shear_set_4800m_u(dry; u = -8.0))    # = CM1 ASdryu4800-8

# Control: the idealized EKAMSAT sounding (IdealizedSounding, defined 1010–10 hPa), on 5 hPa
# levels put on heights hydrostatically. The surface is its lowest level, 1010 hPa. The initial
# wind is the sounding's, to shorten the inertial adjustment to the geostrophic wind.
using IdealizedSounding

"""
    hydrostatic_heights(p, T, r)

Heights (m) of the pressure levels `p` (decreasing; any unit) above the first level, from the
hypsometric equation with the virtual temperature of `T` (K) and vapor mixing ratio `r` (kg/kg),
integrated trapezoidally in ln p. Puts a pressure-coordinate sounding on heights for
`Sounding(p₀, z, θ, r, u, v)`.
"""
function hydrostatic_heights(p, T, r)
    Rᵈ, g, ε = 287.04, 9.81, 0.622                       # J kg⁻¹ K⁻¹, m s⁻², Rᵈ/Rᵛ
    Tᵛ = @. T * (1 + r / ε) / (1 + r)
    z = zeros(length(p))
    for k in 2:length(p)
        z[k] = z[k-1] + Rᵈ / g * (Tᵛ[k-1] + Tᵛ[k]) / 2 * log(p[k-1] / p[k])
    end
    return z
end

p_levels = sort(unique([1010.0:-5.0:10.0; geostrophic_bottom_pressure; vapor_source_layer...]); rev = true)   # hPa
ideal = idealized_sounding(p_levels)
z_levels = hydrostatic_heights(ideal.p, ideal.T, ideal.r)
sounding = Sounding(100 * ideal.p[1], z_levels, Float64.(ideal.θ), Float64.(ideal.r),
                    Float64.(ideal.u), Float64.(ideal.v))
level_height(p) = z_levels[findfirst(==(p), p_levels)]   # m, of a pressure level (hPa) in p_levels
geostrophic_bottom = level_height(geostrophic_bottom_pressure)
vapor_source_heights = Float64.(level_height.(vapor_source_layer))   # (bottom, top), m
sea_surface_temperature = ideal.T[1] + sst_offset               # K

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
sponge_rate = 1 / sponge_timescale

# Vertical grid: CM1's levels (50 m at the surface stretching to 500 m by 5 km, then 500 m) up to
# z_stretch = 18 km, then Δz increasing linearly to about Δz_top at the 28 km lid. Coarser levels
# in the stratosphere and sponge improve the conditioning of the anelastic pressure solve for the
# longest horizontal waves and save ~11% of the cells (CM1 itself used 500 m to the top).
function stretched_top_faces(; z_stretch = 18000, z_top = 28000, Δz_top = 1000)
    lower = filter(≤(z_stretch), MonsoonConvection.cm1_z_faces())
    Δz₀ = lower[end] - lower[end-1]                      # 500 m
    L = z_top - lower[end]
    n = round(Int, 2L / (Δz₀ + Δz_top))                  # cells, linear Δz from Δz₀ to ~Δz_top
    Δz₁ = 2L / n - Δz₀                                   # adjusted so the faces end exactly at z_top
    Δz = [Δz₀ + (Δz₁ - Δz₀) * (i - 1) / (n - 1) for i in 1:n]
    faces = Float64.(vcat(lower, lower[end] .+ cumsum(Δz)))
    faces[end] = z_top                                   # exactly, despite rounding
    return faces
end

z_faces = stretched_top_faces(Δz_top = 1000)

model = build_model(sounding; arch = hardware, Nx, Ny, z_faces, sponge_variables, sponge_rate,
                    bounded_scalar_advection = bounded_advection,
                    microphysics, geostrophic_bottom, sea_surface_temperature,
                    vapor_source_rate = vapor_source_rate / day, vapor_source_layer = vapor_source_heights,
                    pressure_solver_float_type = breeze_solver_precision ? pressure_solver_type : nothing)

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
simulation = build_simulation(model; stop_time, wall_time_limit, small_test, restart, prefix, sedimentation_cfl,
                              checkpoint_interval)

@info "Monsoon convection: $(Nx)×$(Ny)×$(size(model.grid, 3)) on $(hardware) in $(Oceananigans.defaults.FloatType), " *
      "stop time $(prettytime(stop_time)), wall-time limit $(isinf(wall_time_limit) ? "none" : prettytime(wall_time_limit))"

restart && restore_latest_checkpoint!(simulation)

if implicit_rain_sink
    include(joinpath(repo, "helpers", "implicit_rain_sink_correction.jl"))
    Base.invokelatest(add_implicit_rain_sink_correction!, simulation)
end

#####
##### debug_nan: every 10 iterations, print field extremes and stop at the first NaN/Inf in any
##### prognostic field, reporting where it is (for diagnosing blow-ups)
#####

using Printf
using Oceananigans: prognostic_fields
using Oceananigans.Grids: znodes

if debug_nan
    # A NaN reaches every prognostic field within one step (through the pressure solve), so
    # prognostic fields can't show where it started. Diagnostic fields (temperature, microphysics
    # diagnostics and fall speeds, TKE diffusivities, radiative heating) are computed from the
    # state each step and feed the next one: a NaN produced by one of them shows up there first,
    # localized. So check everything every iteration, and list each field with bad points.
    m = simulation.model
    μ = m.microphysical_fields
    checked_fields = merge(prognostic_fields(m),
                           (; T = m.temperature, Fᴿ = m.radiation.flux_divergence),
                           NamedTuple(n => getproperty(m.closure_fields, n) for n in (:Kᵘ, :Kᶜ, :Kᵉ)),
                           NamedTuple(n => μ[n] for n in keys(μ) if !startswith(string(n), "ρ") && μ[n] isa Field))
    fall_rate = sedimentation_rate_profile(m)    # per-level max |w + w_fall| / Δz

    function check_nan(sim)
        if iteration(sim) % 10 == 0
            # value and height of the maximum of a field (copied to the host)
            where_max(f) = (data = Array(interior(f)); (v, I) = findmax(data); (v, Array(znodes(f))[I[3]]))
            where_min(f) = (data = Array(interior(f)); (v, I) = findmin(data); (v, Array(znodes(f))[I[3]]))
            K, zK = where_max(m.closure_fields.Kᵘ)
            T, zT = where_max(m.temperature)
            # ice number: P3 only
            ice_number = haskey(μ, :nⁱ) ? (@sprintf("max nⁱ = %.3g /kg at z = %.0f m, ", where_max(μ.nⁱ)...)) : ""
            F⁺, zF⁺ = where_max(m.radiation.flux_divergence)
            F⁻, zF⁻ = where_min(m.radiation.flux_divergence)
            Tᵗᵒᵖ = Array(interior(m.temperature))[:, :, end]          # top cell
            # vertical velocity above 20 km (the sponge), and how many faces have K at the cap
            wdata = Array(interior(m.velocities.w)); zw = Array(znodes(m.velocities.w))
            upper = findall(zw .> 20000)
            wᵘᵖ, Iᵘᵖ = findmax(abs, view(wdata, :, :, upper))
            Kdata = Array(interior(m.closure_fields.Kᵘ))
            ncap = count(≥(0.999 * m.closure.maximum_viscosity), Kdata)
            @printf("debug iter %d, t = %s, Δt = %.2f s: max|w| = %.3g, min T = %.1f, max T = %.1f at z = %.0f m, max qcl = %.3g, qr = %.3g, qi = %.3g g/kg, max Kᵘ = %.3g at z = %.0f m\n",
                    iteration(sim), prettytime(sim), sim.Δt, maximum(abs, m.velocities.w), minimum(m.temperature),
                    T, zT, 1e3maximum(μ.qᶜˡ), 1e3maximum(μ.qʳ), 1e3maximum(μ.qⁱ), K, zK)
            @printf("    top cell T ∈ [%.2f, %.2f] K, %sFᴿ ∈ [%.3g at z = %.0f m, %.3g at z = %.0f m] W/m³\n",
                    minimum(Tᵗᵒᵖ), maximum(Tᵗᵒᵖ), ice_number, F⁻, zF⁻, F⁺, zF⁺)
            # horizontal wavelength of the top-cell T anomaly, from sign changes along x
            Tᵃ = Tᵗᵒᵖ .- sum(Tᵗᵒᵖ) / length(Tᵗᵒᵖ)
            nx = size(Tᵃ, 1)
            crossings = sum(count(i -> sign(Tᵃ[i, j]) != sign(Tᵃ[mod1(i + 1, nx), j]), 1:nx) for j in axes(Tᵃ, 2)) / size(Tᵃ, 2)
            λ = crossings > 0 ? 2 * m.grid.Lx / crossings / 1e3 : Inf
            compute!(fall_rate)
            Cˢ, kˢ = findmax(vec(Array(interior(fall_rate))))
            @printf("    max|w| above 20 km = %.3g m/s at z = %.0f m, faces with Kᵘ at the cap: %d, top-cell T anomaly wavelength ≈ %.1f km\n",
                    wᵘᵖ, zw[upper[Iᵘᵖ[3]]], ncap, λ)
            @printf("    max sedimentation Courant number |w + w_fall| Δt / Δz = %.3g at z = %.0f m\n",
                    Cˢ * sim.Δt, zw[kˢ])
        end
        all(f -> all(isfinite, interior(f)), values(checked_fields)) && return nothing

        println("NaN/Inf at iteration $(iteration(sim)), t = $(prettytime(sim)), Δt = $(sim.Δt). Fields, fewest bad points first:")
        reports = []
        for (name, field) in pairs(checked_fields)
            bad = findall(!isfinite, Array(interior(field)))
            isempty(bad) || push!(reports, (name, field, bad))
        end
        for (name, field, bad) in sort(reports; by = r -> length(r[3]))
            i, j, k = Tuple(first(bad))
            ks = sort(unique(getindex.(Tuple.(bad), 3)))
            @printf("  %-6s %8d points; first (i, j, k) = (%d, %d, %d) at z = %.0f m; levels k = %s\n",
                    name, length(bad), i, j, k, Array(znodes(field))[k],
                    length(ks) > 12 ? "$(first(ks))–$(last(ks)) ($(length(ks)) levels)" : string(ks))
        end
        error("stopping at first NaN/Inf")
    end

    add_callback!(simulation, check_nan, IterationInterval(1))
end


#####
##### Check that bounded scalars stay within their advection limiter's bounds
#####
#
# The bounds-preserving limiter assumes every cell value already lies within its bounds. If a
# source (radiation, latent heating, microphysics) pushes a value outside, the limiter misbehaves.
# Every 10 iterations, compare the specific value (e.g. θ = ρθ/ρᵣ, q = ρq/ρᵣ) of each bounded
# scalar with its bounds. The first violation of each field gets a full warning; with debug_nan,
# every violation then gets one line with the location, height and temperature of the offending
# extreme. A relative tolerance of 1e-6 ignores round-off-level values such as -1e-18.

using Oceananigans.Advection: BoundsPreservingWENO

if bounded_advection
    let m = simulation.model, debug = debug_nan
        bounded_names = Tuple(name for (name, scheme) in pairs(m.advection) if scheme isa BoundsPreservingWENO)
        ρᵣ = m.dynamics.reference_state.density
        specific = NamedTuple(name => Field(prognostic_fields(m)[name] / ρᵣ) for name in bounded_names)
        warned = Set{Symbol}()

        # Location of the minimum or maximum of f's interior. findmin/findmax run on the GPU when
        # they can; otherwise (e.g. no GPU method for the view) the field is copied to the CPU.
        function extreme_location(f, find)
            data = interior(f)
            value, I = try find(data) catch; find(Array(data)) end
            return value, Tuple(I)
        end
        cell_value(f, i, j, k) = Array(view(interior(f), i:i, j:j, k:k))[1]

        function check_limiter_bounds(sim)
            for name in bounded_names
                f = specific[name]
                compute!(f)
                lo, hi = m.advection[name].bounds.minimum_value, m.advection[name].bounds.maximum_value
                fmin, fmax = minimum(f), maximum(f)
                tolerance = 1e-6 * max(abs(fmin), abs(fmax), eps(Float32))
                below, above = fmin < lo - tolerance, fmax > hi + tolerance
                (below || above) || continue
                if name ∉ warned
                    @warn "$name: specific value range [$fmin, $fmax] at iteration $(iteration(sim)) " *
                          "(t = $(prettytime(sim))) is outside its advection bounds [$lo, $hi]. The " *
                          "bounds-preserving limiter is unreliable there: check the sources or the bounds " *
                          "(MonsoonConvection.scalar_bounds)." *
                          (debug ? " Further violations are reported one per line." : "")
                    push!(warned, name)
                end
                if debug
                    value, (i, j, k) = extreme_location(f, below ? findmin : findmax)
                    z = Array(znodes(f))[k]
                    T = cell_value(m.temperature, i, j, k)
                    @printf("bounds %-5s iter %d  t %s  range [%.3e, %.3e]  %s at (i, j, k) = (%d, %d, %d)  z = %.0f m  T = %.2f K\n",
                            name, iteration(sim), prettytime(sim), fmin, fmax, below ? "min" : "max",
                            i, j, k, z, T)
                end
            end
            return nothing
        end

        add_callback!(simulation, check_limiter_bounds, IterationInterval(10))
    end
end

# Errors can be thousands of lines (CUDA lists every field of a non-isbits argument, and stack
# frames print full type parameters). Keep the log short: write the whole error to error.log
# in the run directory, and print only its first 40 lines, each cut to 200 characters.
try
    run_simulation!(simulation)
catch err
    full = sprint(showerror, err, catch_backtrace())
    write("error.log", full)
    lines = split(full, '\n')
    clip(line) = length(line) > 200 ? first(line, 200) * " …" : line
    println(stderr, "ERROR: ", join(clip.(first(lines, 40)), '\n'))
    println(stderr, "(full error, $(length(lines)) lines: $(abspath("error.log")))")
    exit(1)
end
