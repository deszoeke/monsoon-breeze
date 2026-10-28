# Run-time diagnostics for monsoon_convection.jl (included by it; not run directly):
#   add_nan_check!(simulation; sponge_bottom)   debug_nan = true
#   add_limiter_bounds_check!(simulation; debug) bounded_advection = true

using Printf
using Oceananigans: prognostic_fields
using Oceananigans.Grids: znodes
using Oceananigans.Advection: BoundsPreservingWENO

"""
    add_nan_check!(simulation; sponge_bottom = 20000)

Every 10 iterations print field extremes; every iteration stop at the first NaN/Inf, listing each
bad field with its location.

A NaN reaches every prognostic field within one step (through the pressure solve), so prognostic
fields can't show where it started. Diagnostic fields (temperature, microphysics diagnostics and
fall speeds, TKE diffusivities, radiative heating) are computed from the state each step and feed
the next one: a NaN produced by one of them shows up there first, localized. So check everything
every iteration, and list each field with bad points, fewest first.
"""
function add_nan_check!(simulation; sponge_bottom = 20000)
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
            # vertical velocity in the sponge, and how many faces have K at the cap
            wdata = Array(interior(m.velocities.w)); zw = Array(znodes(m.velocities.w))
            upper = findall(zw .> sponge_bottom)
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
            @printf("    max|w| above %.0f km = %.3g m/s at z = %.0f m, faces with Kᵘ at the cap: %d, top-cell T anomaly wavelength ≈ %.1f km\n",
                    sponge_bottom / 1e3, wᵘᵖ, zw[upper[Iᵘᵖ[3]]], ncap, λ)
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
    return nothing
end

"""
    add_limiter_bounds_check!(simulation; debug = false)

Check that bounded scalars stay within their advection limiter's bounds.

The bounds-preserving limiter assumes every cell value already lies within its bounds. If a source
(radiation, latent heating, microphysics) pushes a value outside, the limiter misbehaves. Every 10
iterations, compare the specific value (e.g. θ = ρθ/ρᵣ, q = ρq/ρᵣ) of each bounded scalar with its
bounds. The first violation of each field gets a full warning; with `debug`, every violation then
gets one line with the location, height and temperature of the offending extreme. A relative
tolerance of 1e-6 ignores round-off-level values such as -1e-18.
"""
function add_limiter_bounds_check!(simulation; debug = false)
    m = simulation.model
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
    return nothing
end
