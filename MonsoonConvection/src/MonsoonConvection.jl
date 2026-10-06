"""
    MonsoonConvection

Reusable machinery for the Breeze.jl translation of the CM1 (r21.1) EKAMSAT Arabian Sea
monsoon-convection case (adapted from CM1 `cpm_RadConvEquil`). See `../monsoon_convection.jl`
for the CM1 → Breeze mapping.

Everything that is experiment-specific (the sounding, initial conditions, grid size, run
length) is passed in as *values*, so that new experiments reuse this package's precompiled
code. In particular the sounding is a [`Sounding`](@ref) of `Vector{Float64}`s: its length and
values never change any type, and the forcing kernels read the geostrophic wind from a
precomputed `Field`, never from the sounding itself.
"""
module MonsoonConvection

export Sounding, read_cm1_sounding, build_model, set_initial_conditions!,
       build_simulation, restore_latest_checkpoint!, run_simulation!

using Breeze
using Breeze: BulkDrag, BulkSensibleHeatFlux, BulkVaporFlux
using Oceananigans
using Oceananigans.Units
using Oceananigans.Grids: znodes
using Oceananigans.TimeSteppers: update_state!
using Oceananigans.Architectures: on_architecture

using NCDatasets  # required for RRTMGP lookup tables
using RRTMGP

using Logging
using PrecompileTools
using Printf
using Random
using Statistics

#####
##### Sounding
#####

"""
    Sounding(p₀, z, θ, r, u, v)

Environmental profile on heights `z` (m, increasing) of potential temperature `θ` (K),
water-vapor mixing ratio `r` (kg/kg) and wind `u`, `v` (m/s), with surface pressure `p₀` (Pa).
Profiles are interpolated linearly in `z` and held constant beyond the end points, as CM1 does.
"""
struct Sounding
    p₀ :: Float64
    z  :: Vector{Float64}
    θ  :: Vector{Float64}
    r  :: Vector{Float64}
    u  :: Vector{Float64}
    v  :: Vector{Float64}

    function Sounding(p₀, z, θ, r, u, v)
        n = length(z)
        all(length(q) == n for q in (θ, r, u, v)) ||
            throw(ArgumentError("sounding profiles must all have the same length as z"))
        issorted(z) || throw(ArgumentError("sounding heights z must be increasing"))
        return new(p₀, z, θ, r, u, v)
    end
end

function interpolate_profile(zs, vs, z)
    z ≤ zs[1] && return vs[1]
    for n in 1:length(zs)-1
        if z ≤ zs[n+1]
            return vs[n] + (vs[n+1] - vs[n]) * (z - zs[n]) / (zs[n+1] - zs[n])
        end
    end
    return vs[end]
end

θ̄(s::Sounding, z) = interpolate_profile(s.z, s.θ, z)
q̄ᵗ(s::Sounding, z) = (r = interpolate_profile(s.z, s.r, z); r / (1 + r)) # mixing ratio → specific humidity
ū(s::Sounding, z) = interpolate_profile(s.z, s.u, z)
v̄(s::Sounding, z) = interpolate_profile(s.z, s.v, z)

"""
    read_cm1_sounding(path)

Read a CM1 `isnd = 7` `input_sounding` file. The first line holds surface pressure (hPa),
θ (K) and qv (g/kg); the remaining lines hold z (m), θ (K), qv (g/kg), u and v (m/s).
The surface values are prepended at z = 0, with the wind of the lowest level.
"""
function read_cm1_sounding(path)
    rows = [parse.(Float64, split(line)) for line in eachline(path) if !isempty(strip(line))]
    p_hPa, θ₀, qv₀ = rows[1]
    levels = rows[2:end]
    z = [0.0; [row[1] for row in levels]]
    θ = [θ₀;  [row[2] for row in levels]]
    r = [qv₀; [row[3] for row in levels]] ./ 1000
    u = [levels[1][4]; [row[4] for row in levels]]
    v = [levels[1][5]; [row[5] for row in levels]]
    return Sounding(100p_hPa, z, θ, r, u, v)
end

#####
##### Grid
#####

"""
    cm1_z_faces()

CM1 `stretch_z = 1` with `dz_bot = 50`, `dz_top = 500`, `ztop = 28000`: Δz grows linearly
from 50 m at the surface to 500 m at 5 km (19 cells), then is uniform 500 m to 28 km
(46 cells). Reproduces the `zf` column of `cm1.print.out` exactly.
"""
function cm1_z_faces()
    Δz_stretched = range(50, 500, length=20)[1:19]
    return vcat(0, cumsum(Δz_stretched), 5500:500:28000)
end

#####
##### Forcing kernels
#####

# CM1 lspgrad = 1: pressure gradient in geostrophic balance with the initial wind,
#   ∂u/∂t = … + f (v - vᵍ),   ∂v/∂t = … - f (u - uᵍ).
@inline geostrophic_u_forcing(i, j, k, grid, clock, model_fields, p) =
    @inbounds - p.ρᵣ[i, j, k] * p.f * p.vᵍ[1, 1, k]

@inline geostrophic_v_forcing(i, j, k, grid, clock, model_fields, p) =
    @inbounds + p.ρᵣ[i, j, k] * p.f * p.uᵍ[1, 1, k]

"""
CM1 `irdamp` damping profile: sin²(π/2 × (z - bottom) / (top - bottom)) above `bottom`.
"""
struct SinSquaredMask{FT}
    bottom :: FT
    top :: FT
end

@inline (m::SinSquaredMask)(x, y, z) =
    ifelse(z > m.bottom, sin(π / 2 * (z - m.bottom) / (m.top - m.bottom))^2, zero(z))

@inline function tropical_ozone(z)
    troposphere_O₃ = 30e-9 * (1 + 0.5 * z / 10_000)
    zˢᵗ = 25e3
    Hˢᵗ = 5e3
    stratosphere_O₃ = 8e-6 * exp(-((z - zˢᵗ) / Hˢᵗ)^2)
    χˢᵗ = 1 / (1 + exp(-(z - 15e3) / 2))
    return troposphere_O₃ * (1 - χˢᵗ) + stratosphere_O₃ * χˢᵗ
end

#####
##### Model
#####
#
# Where the grid and physics are specified
# -----------------------------------------
# build_model below is the one place that defines the grid and the physics:
#   GRID SPECIFICATION     RectilinearGrid: size, extent, halo, vertical faces,
#                          topology (periodic laterally, bounded vertically)
#   PHYSICS SPECIFICATION  reference state, Coriolis + geostrophic forcing, sponge,
#                          surface fluxes, radiation, microphysics, turbulence closure,
#                          advection schemes
#
# Two kinds of change:
#  • Parameter values (Δx, z_faces, SST, CO₂, sponge depth, ...) are keyword arguments
#    of build_model. Set them from the driver (monsoon_convection.jl); no recompile.
#    To expose a new parameter, add a keyword here once (one recompile), then vary it
#    freely from the driver.
#  • Changing a scheme or its type (e.g. P3Microphysics → OneMomentCloudMicrophysics,
#    a different closure or advection scheme, a new forcing function) means editing
#    this file. That recompiles the package: rerun
#        julia --project setup_precompile.jl
#    so the precompile workload is rebuilt before the next production run.
#
# Experiment inputs (sounding, initial conditions) do NOT go here; they belong in the
# driver. See the comments there.

"""
    build_model(sounding::Sounding; arch=CPU(), Nx, Ny, kw...)

Build the `AtmosphereModel` for the CM1 monsoon-convection case. The float type is
`Oceananigans.defaults.FloatType` at call time. Keyword arguments (CM1 namelist values
by default) are values, not types, so changing them reuses the precompiled code.
"""
function build_model(sounding::Sounding;
                     arch = CPU(),
                     Nx, Ny,
                     Δx = 500, Δy = Δx,                 # CM1 dx, dy
                     z_faces = cm1_z_faces(),           # CM1 stretch_z = 1
                     sea_surface_temperature = 301,     # CM1 tsk0 (oceanmodel = 1: fixed SST)
                     gustiness = 1,
                     coriolis_parameter = 2.53252496e-5, # CM1 fcor (10°N)
                     sponge_bottom = 20000,             # CM1 zd
                     sponge_rate = 1/300,               # CM1 rdalpha (irdamp = 2: w only)
                     surface_albedo = 0.08,             # from cm1.print.out
                     solar_constant = 650.83,           # perpetual sun, from cm1.print.out
                     cos_zenith = 0.6360782,
                     CO₂ = 387.75e-6,
                     radiation_interval = 300,          # CM1 dtrad
                     maximum_diffusivity = 100)         # m² s⁻¹, cap on the TKE closure's K (see below)

    FT = Oceananigans.defaults.FloatType
    s = sounding
    Nz = length(z_faces) - 1

    #####
    ##### GRID SPECIFICATION (CM1 &param0, &param1, &param6, wbc/ebc/sbc/nbc = 1)
    #####

    grid = RectilinearGrid(arch; size = (Nx, Ny, Nz), halo = (5, 5, 5),
                           x = (0, Nx * Δx), y = (0, Ny * Δy), z = z_faces,
                           topology = (Periodic, Periodic, Bounded))

    #####
    ##### PHYSICS SPECIFICATION (everything from here to the AtmosphereModel call)
    #####

    constants = ThermodynamicConstants()

    # Hydrostatic reference state from the sounding's θ and qᵛ
    reference_state = ReferenceState(grid, constants;
                                     base_pressure = s.p₀,
                                     potential_temperature = z -> θ̄(s, z),
                                     vapor_mass_fraction = z -> q̄ᵗ(s, z))

    dynamics = AnelasticDynamics(reference_state)

    # Coriolis and geostrophic forcing (CM1 icor = 1, lspgrad = 1)
    coriolis = FPlane(f = coriolis_parameter)

    zᶜ = Array(znodes(grid, Center()))
    uᵍ = Field{Nothing, Nothing, Center}(grid)
    vᵍ = Field{Nothing, Nothing, Center}(grid)
    set!(uᵍ, reshape(FT[ū(s, z) for z in zᶜ], 1, 1, Nz))
    set!(vᵍ, reshape(FT[v̄(s, z) for z in zᶜ], 1, 1, Nz))

    geostrophic_parameters = (; ρᵣ = reference_state.density, f = FT(coriolis_parameter), uᵍ, vᵍ)
    ρu_forcing = Forcing(geostrophic_u_forcing; discrete_form=true, parameters=geostrophic_parameters)
    ρv_forcing = Forcing(geostrophic_v_forcing; discrete_form=true, parameters=geostrophic_parameters)

    # Upper Rayleigh damping of w (CM1 irdamp = 2)
    mask = SinSquaredMask(FT(sponge_bottom), FT(last(z_faces)))
    ρw_sponge = Relaxation(rate = sponge_rate, mask = mask)

    forcing = (; ρu=ρu_forcing, ρv=ρv_forcing, ρw=ρw_sponge)

    # Bulk surface fluxes over fixed SST (CM1 sfcmodel = 1, oceanmodel = 1)
    Tˢ = sea_surface_temperature
    coefficient = PolynomialCoefficient()
    flux_kw = (; coefficient, gustiness, surface_temperature = Tˢ)

    boundary_conditions = (ρu  = FieldBoundaryConditions(bottom = BulkDrag(; flux_kw...)),
                           ρv  = FieldBoundaryConditions(bottom = BulkDrag(; flux_kw...)),
                           ρE  = FieldBoundaryConditions(bottom = BulkSensibleHeatFlux(; flux_kw...)),
                           ρqᵗ = FieldBoundaryConditions(bottom = BulkVaporFlux(; flux_kw...)))

    # Radiation (CM1 radopt = 2: RRTMG, no diurnal cycle)
    background_atmosphere = BackgroundAtmosphere(; CO₂, CH₄ = 1650e-9, N₂O = 306e-9, O₃ = tropical_ozone)

    radiation = RadiativeTransferModel(grid, AllSkyOptics(), constants;
                                       surface_temperature = Tˢ,
                                       surface_albedo,
                                       solar_constant,
                                       solar_position = FixedCosineZenith(cos_zenith),
                                       background_atmosphere,
                                       schedule = TimeInterval(radiation_interval),
                                       liquid_effective_radius = ConstantRadiusParticles(10e-6),
                                       ice_effective_radius = ConstantRadiusParticles(30e-6))

    # Microphysics (CM1 ptype = 5: Morrison 2-moment with ice → P3)
    #
    # Built directly on `arch`: Breeze (0.11.3 and main as of Oct 2026) embeds the microphysics
    # in the surface-flux boundary conditions (energy-flux conversion, stability-dependent bulk
    # coefficient) *before* AtmosphereModel moves the microphysics to the GPU, so those boundary
    # conditions kept CPU lookup tables and GPU kernels failed with "not isbits". Moving P3
    # first makes both share the device copy; on CPU this is a no-op.
    microphysics = on_architecture(arch, P3Microphysics())

    # PBL turbulence (CM1 ipbl = 2, no LES subgrid model)
    #
    # The closure's mixing length is ℓ = min(z, Cᴺ√e/N): where N² ≤ 0 it becomes the height above
    # the ground, so a locally unstable layer aloft (e.g. near 20 km) gets ℓ ~ 20 km and
    # K = Sᵘ ℓ √e ~ 10⁴–10⁵ m² s⁻¹, which ran away and ended in NaN on the full GPU domain.
    # CM1's PBL scheme instead limits the mixing length (l_inf = 75 m, i.e. K ≲ 50 m² s⁻¹).
    # Breeze has no mixing-length limit, so cap the diffusivities; maxima in normal runs are
    # ~40 m² s⁻¹, so the cap only acts on a runaway.
    closure = TKEBasedTurbulenceClosure(; maximum_viscosity = maximum_diffusivity,
                                          maximum_tracer_diffusivity = maximum_diffusivity,
                                          maximum_tke_diffusivity = maximum_diffusivity)

    return AtmosphereModel(grid; dynamics, coriolis, microphysics, radiation, closure,
                           forcing, boundary_conditions,
                           momentum_advection = WENO(order=5),
                           scalar_advection = WENO(order=5))
end

"""
    set_initial_conditions!(model, sounding; δθ=0.25, seed=2023)

CM1 `isnd = 7`, `irandp = 1` initialization: the sounding plus ±`δθ` K random θ
perturbations. Experiments may instead call `set!(model; ...)` with their own functions.

Note the variables `set!` expects: `θ` is the liquid-ice potential temperature (equal to
the potential temperature while the air is unsaturated), and `qᵗ` is the total-water
*specific humidity* qᵗ = r / (1 + r), not the mixing ratio r used in the sounding.
"""
function set_initial_conditions!(model, s::Sounding; δθ = 0.25, seed = 2023)
    Random.seed!(seed)
    set!(model; θ  = (x, y, z) -> θ̄(s, z) + δθ * (2rand() - 1),
                qᵗ = (x, y, z) -> q̄ᵗ(s, z),
                u  = (x, y, z) -> ū(s, z),
                v  = (x, y, z) -> v̄(s, z))
    return model
end

#####
##### Simulation and output
#####

# NetCDF variable names: plain ASCII, so they are easy to use from Python, MATLAB, ncview.
# Unicode superscripts are folded to letters (ᶜˡ → cl), ρ → rho_, θ → theta.
function netcdf_name(name)
    str = Base.Unicode.normalize(string(name); compat = true)
    str = replace(str, "ρ" => "rho_", "θ" => "theta", "²" => "2")
    return Symbol(map(c -> isascii(c) ? c : '_', str))
end

const hydrometeors = Dict("cl" => "cloud liquid", "r" => "rain", "i" => "ice (total)",
                          "f" => "rime on ice", "wi" => "liquid water on ice")

function netcdf_attributes(name::Symbol)
    known = Dict(:u     => ("eastward wind", "m s-1"),
                 :v     => ("northward wind", "m s-1"),
                 :w     => ("upward wind", "m s-1"),
                 :theta => ("liquid-ice potential temperature", "K"),
                 :T     => ("temperature", "K"),
                 :qv    => ("water vapor mass fraction (specific humidity)", "kg kg-1"),
                 :bf    => ("rime volume per mass of moist air", "m3 kg-1"),
                 :radiative_flux_divergence => ("radiative flux divergence (heating rate × ρ cp)", "W m-3"),
                 :w2    => ("vertical velocity variance", "m2 s-2"))
    haskey(known, name) && return Dict("long_name" => known[name][1], "units" => known[name][2])

    str = string(name)
    kind, suffix = str[1], str[2:end]
    hydrometeor = get(hydrometeors, suffix, suffix)
    kind == 'q' && return Dict("long_name" => "$hydrometeor mass fraction", "units" => "kg kg-1")
    kind == 'n' && return Dict("long_name" => "$hydrometeor number per mass of moist air", "units" => "kg-1")
    return Dict("long_name" => "microphysics variable $str")
end

# Microphysics output: the diagnostic mass fractions (q*), numbers per mass (n*) and rime
# volume (bf). Density-weighted prognostics (ρ*) are in the checkpoints, and the
# sedimentation velocities (w*) are internal, so neither is written to NetCDF.
function microphysics_outputs(model)
    fields = model.microphysical_fields
    keep = filter(name -> !startswith(string(name), "ρ") && !startswith(string(name), "w"), keys(fields))
    return NamedTuple(name => fields[name] for name in keep)
end

ascii_outputs(outputs) = NamedTuple(netcdf_name(name) => outputs[name] for name in keys(outputs))

"""
    build_simulation(model; stop_time, small_test=false, restart=false, wall_time_limit=Inf,
                     prefix="monsoon_convection", dir=".", ...)

Simulation with an adaptive time step (CM1 `dtl = 15`, `adapt_dt = 1`), a progress log,
NetCDF output (hourly mean profiles and lowest-level fields, CM1 `statfrq`; 3D fields every
`fields_interval`, CM1 `tapfrq`) and checkpoints for restarts (CM1 `rstfrq`).

- `stop_time` is the *total* simulated time in seconds, counted from the start of the
  original run, also for restarts.
- `wall_time_limit` (seconds of real time) stops the run cleanly; [`run_simulation!`](@ref)
  then writes a checkpoint so the run can be continued with a restart. Set it a little
  below the batch job's time limit.
- With `restart = true`, output is appended to the existing NetCDF files.
"""
function build_simulation(model;
                          stop_time,
                          stop_iteration = Inf,
                          wall_time_limit = Inf,
                          small_test = false,
                          restart = false,
                          prefix = "monsoon_convection",
                          dir = ".",
                          Δt = 1,
                          cfl = 0.7,
                          max_Δt = 15,
                          progress_interval = small_test ? 10 : 100,
                          profiles_interval = 1hour,
                          surface_interval = 1hour,
                          fields_interval = small_test ? 30minutes : 1day,
                          checkpoint_interval = fields_interval)

    simulation = Simulation(model; Δt, stop_time, stop_iteration, wall_time_limit)
    conjure_time_step_wizard!(simulation; cfl, max_Δt)
    Oceananigans.Diagnostics.erroring_NaNChecker!(simulation)

    u, v, w = model.velocities
    θ = liquid_ice_potential_temperature(model)
    T = model.temperature
    qᵛ = specific_humidity(model)
    radiation = model.radiation
    Nz = size(model.grid, 3)

    wall_clock = Ref(time_ns())

    function progress(sim)
        elapsed = 1e-9 * (time_ns() - wall_clock[])
        OLR = mean(view(radiation.upwelling_longwave_flux, :, :, Nz+1))

        msg = @sprintf("Iter: %6d, t: %10s, Δt: %5.2f s, wall: %10s",
                       iteration(sim), prettytime(sim), sim.Δt, prettytime(elapsed))
        msg *= @sprintf(", max|u|: (%.1f, %.1f, %.1f) m/s, T ∈ [%.1f, %.1f] K, max(qᵛ): %.2f g/kg, OLR: %.1f W/m²",
                        maximum(abs, u), maximum(abs, v), maximum(abs, w),
                        minimum(T), maximum(T), 1e3 * maximum(qᵛ), OLR)
        @info msg

        wall_clock[] = time_ns()
        return nothing
    end

    add_callback!(simulation, progress, IterationInterval(progress_interval))

    # Thermodynamic and kinematic fields, plus hydrometeor mass fractions and numbers
    outputs = ascii_outputs(merge((; u, v, w, θ, T, qᵛ), microphysics_outputs(model)))

    profiles = NamedTuple(name => Average(outputs[name], dims=(1, 2)) for name in keys(outputs))
    profiles = merge(profiles, (radiative_flux_divergence = Average(radiation.flux_divergence, dims=(1, 2)),
                                w2 = Average(w^2, dims=(1, 2))))

    output_attributes(outs) = Dict(string(name) => netcdf_attributes(name) for name in keys(outs))
    global_attributes = Dict("title" => "CM1 monsoon-convection case (EKAMSAT) in Breeze.jl",
                             "source" => "MonsoonConvection.jl")

    netcdf_kw = (; dir, global_attributes, overwrite_files = !restart)

    simulation.output_writers[:profiles] =
        NetCDFWriter(model, profiles; netcdf_kw..., output_attributes = output_attributes(profiles),
                     filename = prefix * "_profiles.nc",
                     schedule = AveragedTimeInterval(profiles_interval))

    simulation.output_writers[:surface] =
        NetCDFWriter(model, outputs; netcdf_kw..., output_attributes = output_attributes(outputs),
                     filename = prefix * "_surface.nc",
                     indices = (:, :, 1),
                     schedule = TimeInterval(surface_interval))

    simulation.output_writers[:fields] =
        NetCDFWriter(model, outputs; netcdf_kw..., output_attributes = output_attributes(outputs),
                     filename = prefix * "_fields.nc",
                     schedule = TimeInterval(fields_interval))

    # Restart files (JLD2; only the latest is kept)
    simulation.output_writers[:checkpointer] = Checkpointer(model; dir,
                                                            schedule = TimeInterval(checkpoint_interval),
                                                            prefix = prefix * "_checkpoint",
                                                            cleanup = true)

    return simulation
end

"""
    restore_latest_checkpoint!(simulation)

Restart: restore the latest checkpoint in the simulation's output directory and recompute
Δt from the CFL condition. (The checkpointer does not save Δt; restarting with the initial
Δt would ramp up again at 10% per time-step-wizard update.)
"""
function restore_latest_checkpoint!(simulation)
    model = simulation.model
    set!(simulation; checkpoint=:latest)
    update_state!(model) # restored momentum → velocities, diagnostics
    wizard = simulation.callbacks[:time_step_wizard].func
    simulation.Δt = clamp(wizard.cfl * wizard.cell_advection_timescale(model), wizard.min_Δt, wizard.max_Δt)
    @info "Restarted at iteration $(iteration(simulation)), t = $(prettytime(simulation)), Δt = $(prettytime(simulation.Δt))"
    return simulation
end

"""
    run_simulation!(simulation)

Run to `stop_time` (or the wall-time limit) and always write a final checkpoint, so that
any run can be continued with a restart. Reports why the run stopped.
"""
function run_simulation!(simulation)
    run!(simulation; checkpoint_at_end = true)

    if simulation.model.clock.time >= simulation.stop_time
        @info "Reached stop time $(prettytime(simulation.stop_time)); final checkpoint written."
    elseif simulation.run_wall_time >= simulation.wall_time_limit
        @info "Wall-time limit reached at t = $(prettytime(simulation)); checkpoint written. " *
              "Continue with --restart (same --stop_time, from the same run directory)."
    end
    return simulation
end

#####
##### Precompile warm-up run
#####
#
# PrecompileTools runs this short "workload" while the package precompiles, so that the
# compiled code for everything it touches (model construction, initialization, time
# stepping, output, checkpointing, restart) is cached and need not be compiled at run time.

# Only the types matter for precompilation, so a synthetic sounding suffices.
workload_sounding() = Sounding(101000.0,
                               [0.0, 1000.0, 20000.0, 40000.0],
                               [300.0, 303.0, 400.0, 1000.0],
                               [0.02, 0.015, 1e-5, 0.0],
                               [5.0, 8.0, -5.0, 0.0],
                               zeros(4))

# build → initialize → 3 time steps with output and a checkpoint → restart.
# Nx, Ny match --small_test, because some kernel types (halo fills) carry the grid size.
function run_workload(arch; Nx = 32, Ny = 16)
    s = workload_sounding()
    with_logger(NullLogger()) do
        mktempdir() do dir
            model = build_model(s; arch, Nx, Ny)
            set_initial_conditions!(model, s)
            simulation = build_simulation(model; stop_time = 1hour, stop_iteration = 3,
                                          small_test = true, prefix = "workload", dir)
            run_simulation!(simulation)
            restore_latest_checkpoint!(simulation)
        end
    end
    return nothing
end

@setup_workload begin
    @compile_workload begin
        run_workload(CPU())
    end
end

end # module
