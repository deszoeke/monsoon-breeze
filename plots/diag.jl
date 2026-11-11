# Diagnostics of monsoon_convection.jl output, ported from cm1-out: computations only, no plotting,
# so notebooks plot the results with PythonPlot. Plots from these arrays are in diag.ipynb.
#
#     using Pkg; Pkg.activate("plots")
#     using Revise; includet("diag.jl")
#     f = resolved_flux(rundir, ["qv", "qcl", "qr"])    # ⟨w′qt′⟩(z) from the last 3D snapshot
#
# Mass fractions are kg/kg, heights m, times days (see readers.jl). Breeze `theta` is the
# liquid-ice potential temperature, not CM1's `th`.

include("readers.jl")
include("thermo.jl")
using .Thermo

const g = Thermo.g

# vertical average of a z-face field (Nz+1 levels) to cell centers
faces_to_centers(a) = (a[:, :, 1:end-1] .+ a[:, :, 2:end]) ./ 2

# a snapshot variable of `kind` at time index n, or the sum over several names
function read_sum(rundir, names; kind = "fields", n = last)
    s = read_snapshot(rundir, names[1]; kind, n)
    data = s.data
    for name in names[2:end]
        data = data .+ read_snapshot(rundir, name; kind, n).data
    end
    return merge(s, (; data))
end

"""
    resolved_flux(rundir, names; n = last, prefix = "monsoon_convection")

Horizontal-mean resolved flux ⟨w′a′⟩ (z cell centers) of a = the sum of the 3D variables `names`
(e.g. `["qv", "qcl", "qr"]` for total water, `["theta"]` for θ), from `_fields.nc` at time index `n`
(an integer or `first`/`last`). Primes are deviations from the horizontal mean; w is averaged
from the z faces to cell centers. Returns `(; t, z, flux)`, units of a times m/s. Subgrid
(closure) fluxes are not in the output, so this is the resolved flux only.
"""
function resolved_flux(rundir, names; n = last, prefix = "monsoon_convection")
    w = faces_to_centers(read_snapshot(rundir, "w"; n, prefix).data)
    a = read_sum(rundir, names; n)
    w′ = w .- mean(w; dims = (1, 2))
    a′ = a.data .- mean(a.data; dims = (1, 2))
    return (; t = a.t, z = a.z, flux = vec(mean(w′ .* a′; dims = (1, 2))))
end

"""
    moist_stability(p; n = :, p0 = 101_500.0)

Dry and moist N² (s⁻²) and the bulk Richardson numbers from the profiles `p = read_profiles(rundir)`,
at time indices `n`. N² = g ∂ln θ/∂z with `theta`; the moist N² adds `Nsq_moist_add(T, p)` with
p from `hydrostatic_pressure` (the files hold none). Ri = N² / ((∂u/∂z)² + (∂v/∂z)²) uses centered
differences, so the arrays have Nz - 2 levels (`z` = p.z[2:end-1]). Returns `(; t, z, N2, N2moist, Ri, Rimoist)`, (z, time).
"""
function moist_stability(p; n = :, p0 = 101_500.0)
    θ, T, qv, u, v = (p.theta[:, n], p.T[:, n], p.qv[:, n], p.u[:, n], p.v[:, n])
    θ, T, qv, u, v = (x isa AbstractVector ? reshape(x, :, 1) : x for x in (θ, T, qv, u, v))
    nz, nt = size(θ)
    z = p.z
    inner = 2:nz-1
    dz = z[3:end] .- z[1:end-2]
    ddz(a) = (a[3:end, :] .- a[1:end-2, :]) ./ dz
    N2 = g .* ddz(log.(θ))
    madd = similar(N2)
    for j in 1:nt
        pr = hydrostatic_pressure(z, T[:, j], qv[:, j]; p0)
        madd[:, j] = Nsq_moist_add.(T[inner, j], pr[inner])
    end
    shear2 = ddz(u) .^ 2 .+ ddz(v) .^ 2
    N2moist = N2 .+ madd
    return (; t = p.t[n], z = z[inner], N2, N2moist, Ri = N2 ./ shear2, Rimoist = N2moist ./ shear2)
end
