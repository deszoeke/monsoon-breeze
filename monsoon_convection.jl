# Monsoon convection over the Arabian Sea (EKAMSAT) in Breeze.jl: a 512 km × 256 km doubly periodic
# domain with a 28 km lid, one-moment mixed-phase microphysics, RRTMGP radiation and a fixed SST.
# Edit the settings below in a run directory's copy of this file. Running, output files and
# compilation: README.md. The CM1 case this began from: notes/cm1_migration.md.

using Oceananigans.Units: second, seconds, minute, minutes, hour, hours, day, days

#####
##### Settings
#####

# Run
arch                    = :gpu         # :gpu | :cpu. :gpu stops at once unless CUDA works.
small_test              = false        # true: 32×16 columns (16 × 8 km), 1 h; a code check only
restart                 = true         # continue from restart_checkpoint, appending to this directory's NetCDF
restart_checkpoint      = :latest      # :latest (this directory) | another run's directory, e.g. "../ekamsat-ctl",
                                       # to branch from its newest checkpoint; then set back to :latest
stop_time               = small_test ? 1hour : 7days  # TOTAL simulated time, from the original start
checkpoint_interval     = small_test ? 30minutes : 1hour  # only the latest checkpoint is kept; none on NaN
debug_nan               = true         # print extremes every 10 iterations; stop at the first NaN/Inf

# Domain
Nx, Ny                  = small_test ? (32, 16) : (1024, 512)  # columns, Δx = Δy = 500 m
Δz_top                  = 1000         # m: Δz at the 28 km lid (stretched from 500 m above 18 km)
sponge_bottom           = 20000        # m: the upper sponge starts here

# Sounding and surface
geostrophic_bottom_pressure = 900      # hPa: geostrophic wind = sounding wind above; held at its value below
sst_offset              = 1.0          # K: SST = lowest air temperature of the sounding + sst_offset
δθ                      = 0.25         # K: random initial θ perturbations, ±δθ
seed                    = 2023         # random seed for the perturbations

# Model
float_type              = Float32      # model precision: Float32 (standard on GPUs) | Float64
microphysics            = :one_moment  # :one_moment (cloud liquid, ice, rain, snow) | :p3 (not production ready)
sponge_variables        = :w           # :w damps w only | :all also relaxes u, v, θ to the sounding
sponge_timescale        = 300seconds   # damping time scale at the top

# Experiment: external vapor source, constant and horizontally uniform, vapor only (no heating).
# The control spins up for 2 days with no source; each experiment branches from its 2-day
# checkpoint with a source in one layer: (1000, 850), (850, 650) or (650, 440) hPa.
vapor_source_rate       = 0.0          # kg/kg/day; 0 for the control
vapor_source_layer      = (850, 650)   # (bottom, top) pressures, hPa

# Fixes to Breeze
pressure_solver_type    = Float64      # Float32 is unstable on the full domain (README)
implicit_rain_sink      = false        # not needed: Breeze PR #1066 closed the issue (#1072) in 0.12.1, where
                                       # this is ignored with a warning; Breeze 0.12.0 only

# Stability options
sedimentation_cfl       = true         # the time step also keeps |w + w_fall| Δt / Δz ≤ cfl
bounded_advection       = true         # bounds-preserving WENO for scalars; false: plain WENO(5)

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
##### Sounding
#####

# Control: the idealized EKAMSAT sounding (IdealizedSounding, defined 1010–10 hPa), on 5 hPa
# levels put on heights hydrostatically. The surface is its lowest level, 1010 hPa. The initial
# wind is the sounding's, to shorten the inertial adjustment to the geostrophic wind.
# Other soundings: README.md, "Writing a new experiment"; the CM1 EKAMSAT soundings:
# notes/cm1_migration.md.
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

#####
##### Grid and model
#####

# Vertical grid: 50 m at the surface stretching to 500 m by 5 km, 500 m up to z_stretch = 18 km,
# then Δz increasing linearly to about Δz_top at the 28 km lid (why: notes/cm1_migration.md).
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

z_faces = stretched_top_faces(; Δz_top)

# Grid and physical parameters are keyword values of build_model (defaults: "Model" in
# MonsoonConvection/src/MonsoonConvection.jl), so changing them doesn't recompile.
model = build_model(sounding; arch = hardware, Nx, Ny, z_faces, sponge_variables, sponge_bottom,
                    sponge_rate = 1 / sponge_timescale,
                    bounded_scalar_advection = bounded_advection,
                    microphysics, geostrophic_bottom, sea_surface_temperature,
                    vapor_source_rate = vapor_source_rate / day, vapor_source_layer = vapor_source_heights,
                    pressure_solver_float_type = breeze_solver_precision ? pressure_solver_type : nothing)

# Initial conditions: the sounding plus ±δθ random θ perturbations. For custom initial
# conditions with set!, see README.md, "Writing a new experiment".
restart || set_initial_conditions!(model, sounding; δθ, seed)

#####
##### Run
#####

prefix = small_test ? "monsoon_convection_small_test" : "monsoon_convection"
simulation = build_simulation(model; stop_time, wall_time_limit, small_test, restart, prefix, sedimentation_cfl,
                              checkpoint_interval)

@info "Monsoon convection: $(Nx)×$(Ny)×$(size(model.grid, 3)) on $(hardware) in $(Oceananigans.defaults.FloatType), " *
      "stop time $(prettytime(stop_time)), wall-time limit $(isinf(wall_time_limit) ? "none" : prettytime(wall_time_limit))"

# The checkpoint to restart from: :latest in this directory, or the newest (highest iteration)
# checkpoint in another run's directory
checkpoint_file(latest::Symbol) = latest
function checkpoint_file(dir::String)
    files = filter(f -> occursin(r"_checkpoint_iteration\d+\.jld2$", f), readdir(dir))
    isempty(files) && error("no checkpoint (*_checkpoint_iteration<N>.jld2) in $dir")
    checkpoint_iteration(f) = parse(Int, match(r"_iteration(\d+)\.jld2$", f)[1])
    return joinpath(dir, files[argmax(checkpoint_iteration.(files))])
end

restart && restore_latest_checkpoint!(simulation, checkpoint_file(restart_checkpoint))

if implicit_rain_sink
    include(joinpath(repo, "helpers", "implicit_rain_sink_correction.jl"))
    Base.invokelatest(add_implicit_rain_sink_correction!, simulation)
end

# Diagnostics (helpers/run_diagnostics.jl): debug_nan reports extremes and the first NaN/Inf;
# with bounded_advection, warn when a bounded scalar leaves its limiter's bounds.
include(joinpath(repo, "helpers", "run_diagnostics.jl"))
debug_nan && add_nan_check!(simulation; sponge_bottom)
bounded_advection && add_limiter_bounds_check!(simulation; debug = debug_nan)

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
