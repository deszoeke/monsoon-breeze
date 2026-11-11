# Readers and array helpers for monsoon_convection.jl output, with no plotting library, so that
# both plotter.jl (CairoMakie) and diag.jl (PythonPlot) can include them. See plotter.jl for the
# file layout and usage.

using NCDatasets, JLD2, Statistics

const day = 86400.0                                       # s

#####
##### Reading
#####

output_file(rundir, kind; prefix = "monsoon_convection") = joinpath(rundir, "$(prefix)_$(kind).nc")

read_var(ds, name) = coalesce.(Array(ds[name]), NaN32)    # missing → NaN

# A time index: an integer, or a function of the indices such as first or last; a range or : selects
# several times
time_index(n::Integer, Nt) = n
time_index(n::Union{AbstractRange, Colon}, Nt) = n
time_index(f::Function, Nt) = f(1:Nt)

"""
    read_profiles(rundir; prefix = "monsoon_convection")

Horizontal-mean profiles from `_profiles.nc` as a NamedTuple: `t` (days), `x`, `y`, `z` (cell
centers), `zᶠ` (faces, for w and w2), all m, and each variable as a (z, time) array under its file
name (T, theta, qv, qcl, qci, qr, qsn, u, v, w, w2, radiative_flux_divergence, ...; P3: qi, qf, ...).
"""
function read_profiles(rundir; prefix = "monsoon_convection")
    NCDataset(output_file(rundir, "profiles"; prefix)) do ds
        names = [k for k in keys(ds) if k != "time" && "time" in dimnames(ds[k])]
        merge((; t = ds["time"].var[:] ./ day, x = ds["x_caa"][:], y = ds["y_aca"][:],
                 z = ds["z_aac"][:], zᶠ = ds["z_aaf"][:]),
              NamedTuple(Symbol(k) => read_var(ds, k) for k in names))
    end
end

"""
    read_snapshot(rundir, name; kind = "fields", n = last, prefix = "monsoon_convection")

Variable `name` (as in the file: "w", "qv", "theta", ...) from `_fields.nc` (3D) or, with
`kind = "surface"`, from `_surface.nc` (lowest level). Returns `(; name, units, t, x, y, z, data)`
(m, days). `n` is a time index (an integer, or `first`/`last`): `data` is (x, y, z), `t` a number.
`n` a range or `:` gives several times: `data` is (x, y, z, time), `t` a vector. A full 3D field is
~120 MB per time, so read one time, or `kind = "surface"`.
"""
function read_snapshot(rundir, name; kind = "fields", n = last, prefix = "monsoon_convection")
    NCDataset(output_file(rundir, kind; prefix)) do ds
        v = ds[name]
        xdim, ydim, zdim, _ = dimnames(v)
        nt = time_index(n, size(v, 4))
        (; name, units = get(v.attrib, "units", ""), t = ds["time"].var[nt] ./ day,
           x = ds[xdim][:], y = ds[ydim][:], z = ds[zdim][:], data = coalesce.(v[:, :, :, nt], NaN32))
    end
end

"""
    open_output(rundir, kind; prefix = "monsoon_convection")

The NCDataset of `_profiles.nc`, `_surface.nc` or `_fields.nc` (`kind` "profiles", "surface", "fields"),
read-only, for reading just the part you need: `ds["qv"][:, :, 1, end]` (x, y, z, time), `ds["time"]`,
`keys(ds)`. Close it with `close(ds)`, or use a block: `open_output(rundir, "fields") do ds ... end`.
"""
open_output(rundir, kind; prefix = "monsoon_convection") = NCDataset(output_file(rundir, kind; prefix))

open_output(f::Function, rundir, kind; prefix = "monsoon_convection") =
    NCDataset(f, output_file(rundir, kind; prefix))

"""
    snapshot_times(rundir; kind = "fields", prefix = "monsoon_convection")

Times (days) of the snapshots in `_fields.nc` or `_surface.nc`.
"""
snapshot_times(rundir; kind = "fields", prefix = "monsoon_convection") =
    NCDataset(ds -> ds["time"].var[:] ./ day, output_file(rundir, kind; prefix))

# The interior of a halo-padded array with interior size N
function interior_of(a, N)
    ranges = ntuple(d -> (h = (size(a, d) - N[d]) ÷ 2; h+1:h+N[d]), 3)
    return a[ranges...]
end

"""
    read_checkpoint(rundir; prefix = "monsoon_convection")

The latest model state, from the newest `_checkpoint_iteration<N>.jld2` in `rundir`:
`(; t, iteration, x, y, z, zᶠ, ρᵣ, fields)`, `t` in days, `fields` the ρ-weighted prognostic fields
(ρu, ρv, ρw, ρθ, ρqᵛ, ρqᶜˡ, ρqᶜⁱ, ρqʳ, ρqˢⁿ, ρe) without halos. `checkpoint_snapshot(ck, :ρqᵛ)`
divides by ρᵣ for the specific value.

The checkpoint holds no grid or reference density. Coordinates come from `_profiles.nc`, and
ρᵣ(z) = ⟨ρθ⟩ / ⟨θ⟩: horizontal means, ⟨θ⟩ the hourly-mean profile nearest in time (it changes by
~0.01% in an hour, so ρᵣ is as close).
"""
function read_checkpoint(rundir; prefix = "monsoon_convection")
    files = filter(f -> occursin(Regex("^$(prefix)_checkpoint_iteration\\d+\\.jld2\$"), f), readdir(rundir))
    isempty(files) && error("no $(prefix)_checkpoint_iteration<N>.jld2 in $rundir")
    iteration_of(f) = parse(Int, match(r"_iteration(\d+)\.jld2$", f)[1])
    file = files[argmax(iteration_of.(files))]
    p = read_profiles(rundir; prefix)
    Nx, Ny, Nz = length(p.x), length(p.y), length(p.z)
    # without Oceananigans loaded, JLD2 warns that it reconstructs the Clock type: silence it
    t, iteration, fields = Base.CoreLogging.with_logger(Base.CoreLogging.NullLogger()) do
        jldopen(joinpath(rundir, file)) do f
        clock = f["simulation/model/clock"]
        g = f["simulation/model/fields"]
        fields = NamedTuple(Symbol(k) => interior_of(g["$k/data"], (Nx, Ny, k == "ρw" ? Nz + 1 : Nz))
                            for k in keys(g))
        clock.time / day, clock.iteration, fields
        end
    end
    nt = argmin(abs.(p.t .- t))
    ρᵣ = vec(mean(fields.ρθ; dims = (1, 2))) ./ p.theta[:, nt]
    return (; t, iteration, x = p.x, y = p.y, z = p.z, zᶠ = p.zᶠ, ρᵣ, fields)
end

"""
    checkpoint_snapshot(ck, name)

A checkpoint field divided by the reference density, e.g. `:ρqᵛ` → qᵛ (kg/kg), `:ρw` → w (m/s),
in the form of `read_snapshot`, with `data` (x, y, z).
"""
function checkpoint_snapshot(ck, name)
    ρ = ck.fields[name]
    faces = size(ρ, 3) == length(ck.z) + 1
    ρᵣ = faces ? [ck.ρᵣ[1]; (ck.ρᵣ[1:end-1] .+ ck.ρᵣ[2:end]) ./ 2; ck.ρᵣ[end]] : ck.ρᵣ
    specific = String(chopprefix(string(name), "ρ"))
    units = startswith(specific, "q") ? "kg kg-1" : specific == "θ" ? "K" : specific == "e" ? "m2 s-2" : "m s-1"
    return (; name = specific, units, t = ck.t, x = ck.x, y = ck.y, z = faces ? ck.zᶠ : ck.z,
            data = ρ ./ reshape(ρᵣ, 1, 1, :))
end

#####
##### Helpers
#####

# Replace non-finite values (log10(0) = -Inf) by NaN, which heatmap! leaves blank. For logs of mass
# fractions, which can be slightly negative: log10.(max.(q, 1e-6)).
blank(A) = map(x -> isfinite(x) ? x : oftype(x, NaN), A)

# Color ranges of the finite values of A: the data range, or symmetric about 0 (for :balance)
symmetric_range(A) = (m = maximum(abs, filter(isfinite, A)); m > 0 ? (-m, m) : (-1, 1))

function finite_range(A)
    a = filter(isfinite, A)
    isempty(a) && return (0, 1)
    lo, hi = extrema(a)
    return lo < hi ? (lo, hi) : (lo - 1, hi + 1)
end
