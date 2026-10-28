# Plots of monsoon_convection.jl output: functions that read a run directory and return CairoMakie
# figures. Including this file only defines them.
#
# Interactively (Mac), in plots.ipynb or the REPL, from the repository:
#     using Pkg; Pkg.activate("plots")
#     using Revise; includet("plotter.jl")
#     plot_time_height("run/ekamsat-ctl0")
# On the cluster (no display), write PNGs to <run>/plots:
#     julia --project=plots -e 'include("plotter.jl"); save_plots("run/ekamsat-ctl0")'
# The plots environment (plots/Project.toml) needs `Pkg.instantiate()` once on each machine.
#
# Output files (MonsoonConvection.build_simulation), "monsoon_convection" prefix:
#   _profiles.nc   horizontal means averaged over each hour, (z, time); also radiative_flux_divergence, w2
#   _surface.nc    hourly snapshots of the lowest level, (x, y, 1, time)
#   _fields.nc     3D snapshots, (x, y, z, time): daily (30 min in a small test)
#   _checkpoint_iteration<N>.jld2   the latest model state (ρ-weighted prognostic fields)
# Mass fractions (qv, qcl, ...) are kg/kg in the files and plotted in g/kg. Times are in days.

using CairoMakie, NCDatasets, JLD2, Statistics

const day = 86400.0                                       # s

#####
##### Reading
#####

output_file(rundir, kind; prefix = "monsoon_convection") = joinpath(rundir, "$(prefix)_$(kind).nc")

read_var(ds, name) = coalesce.(Array(ds[name]), NaN32)    # missing → NaN

# A time index: an integer, or a function of the indices such as first or last
time_index(n::Integer, Nt) = n
time_index(f::Function, Nt) = f(1:Nt)

"""
    read_profiles(rundir; prefix = "monsoon_convection")

Horizontal-mean profiles from `_profiles.nc` as a NamedTuple: `t` (days), `x`, `y`, `z` (cell
centers), `zᶠ` (faces, for w and w2), all m, and each variable as a (z, time) array under its file
name (T, theta, qv, qcl, qci, qr, qsn, u, v, w, w2, radiative_flux_divergence, ...).
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

One snapshot of variable `name` (as in the file: "w", "qv", "theta", ...) from `_fields.nc` (3D) or,
with `kind = "surface"`, from `_surface.nc` (lowest level). `n` is a time index, or `first`/`last`.
Returns `(; name, units, t, x, y, z, data)` with `data` (x, y, z), `t` in days.
"""
function read_snapshot(rundir, name; kind = "fields", n = last, prefix = "monsoon_convection")
    NCDataset(output_file(rundir, kind; prefix)) do ds
        v = ds[name]
        xdim, ydim, zdim, _ = dimnames(v)
        nt = time_index(n, size(v, 4))
        (; name, units = get(v.attrib, "units", ""), t = ds["time"].var[nt] / day,
           x = ds[xdim][:], y = ds[ydim][:], z = ds[zdim][:], data = coalesce.(v[:, :, :, nt], NaN32))
    end
end

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
in the form of `read_snapshot` (so it plots with `plot_xz`, `plot_xy`).
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
##### Plots
#####

# Mass fractions in g/kg; everything else in the file's units
display_units(name, units) = startswith(name, "q") ? (1e3, "g/kg") : (1.0, units)

symmetric_range(A) = (m = maximum(abs, filter(isfinite, A)); m > 0 ? (-m, m) : (-1, 1))

# Profile references for anomalies: the first output, or the time mean
first_profile(A) = A[:, 1:1]
time_mean(A) = mean(A; dims = 2)

# One time–height panel at grid position fig[i, 1:2]
function time_height!(fig, i, t, z, A; title, colormap = :viridis, colorrange = Makie.automatic, zmax)
    ax = Axis(fig[i, 1]; title, ylabel = "z (km)", limits = (extrema(t), (0, zmax / 1e3)))
    hm = heatmap!(ax, t, z ./ 1e3, permutedims(A); colormap, colorrange)
    Colorbar(fig[i, 2], hm)
    return ax
end

"""
    plot_time_height(rundir; zmax = 12000, reference = first_profile, prefix = "monsoon_convection")

Time–height sections of the horizontal means: T and qᵛ anomalies from `reference` (`first_profile`,
the first hourly mean, or `time_mean`), cloud condensate (qcl + qci), precipitation (qr + qsn) and
radiative flux divergence (positive: cooling).
"""
function plot_time_height(rundir; zmax = 12_000, reference = first_profile, prefix = "monsoon_convection")
    p = read_profiles(rundir; prefix)
    below = p.z .<= zmax
    T′ = p.T .- reference(p.T)
    q′ = 1e3 .* (p.qv .- reference(p.qv))
    anomaly = reference === first_profile ? "change since t = $(round(p.t[1]; digits = 2)) d" : "anomaly from the time mean"
    fig = Figure(size = (900, 1200), fontsize = 14)
    axes = [time_height!(fig, 1, p.t, p.z, T′; title = "T (K), $anomaly", colormap = :balance,
                         colorrange = symmetric_range(T′[below, :]), zmax),
            time_height!(fig, 2, p.t, p.z, q′; title = "qᵛ (g/kg), $anomaly", colormap = :balance,
                         colorrange = symmetric_range(q′[below, :]), zmax),
            time_height!(fig, 3, p.t, p.z, 1e3 .* (p.qcl .+ p.qci); title = "cloud liquid + ice (g/kg)",
                         colormap = :dense, zmax),
            time_height!(fig, 4, p.t, p.z, 1e3 .* (p.qr .+ p.qsn); title = "rain + snow (g/kg)",
                         colormap = :dense, zmax),
            time_height!(fig, 5, p.t, p.z, p.radiative_flux_divergence; title = "radiative flux divergence (W/m³)",
                         colormap = :balance, colorrange = symmetric_range(p.radiative_flux_divergence[below, :]), zmax)]
    foreach(ax -> hidexdecorations!(ax; grid = false), axes[1:end-1])
    axes[end].xlabel = "time (days)"
    linkxaxes!(axes...)
    return fig
end

"""
    plot_wind_time_height(rundir; zmax = 20000, prefix = "monsoon_convection")

Time–height sections of the horizontal-mean u and v, and the rms vertical velocity √⟨w²⟩.
"""
function plot_wind_time_height(rundir; zmax = 20_000, prefix = "monsoon_convection")
    p = read_profiles(rundir; prefix)
    below = p.z .<= zmax
    fig = Figure(size = (900, 750), fontsize = 14)
    axes = [time_height!(fig, 1, p.t, p.z, p.u; title = "u (m/s)", colormap = :balance,
                         colorrange = symmetric_range(p.u[below, :]), zmax),
            time_height!(fig, 2, p.t, p.z, p.v; title = "v (m/s)", colormap = :balance,
                         colorrange = symmetric_range(p.v[below, :]), zmax),
            time_height!(fig, 3, p.t, p.zᶠ, sqrt.(max.(p.w2, 0)); title = "√⟨w²⟩ (m/s)", colormap = :dense, zmax)]
    foreach(ax -> hidexdecorations!(ax; grid = false), axes[1:end-1])
    axes[end].xlabel = "time (days)"
    linkxaxes!(axes...)
    return fig
end

"""
    plot_profiles(rundir; ns = (first, last), zmax = 16000, prefix = "monsoon_convection")

Horizontal-mean θ, qᵛ, cloud condensate, u and v at the hourly means `ns` (indices, or `first`/`last`).
"""
function plot_profiles(rundir; ns = (first, last), zmax = 16_000, prefix = "monsoon_convection")
    p = read_profiles(rundir; prefix)
    Nt = length(p.t)
    fig = Figure(size = (1200, 500), fontsize = 14)
    panels = [("θ (K)", p.theta), ("qᵛ (g/kg)", 1e3 .* p.qv), ("cloud liquid + ice (g/kg)", 1e3 .* (p.qcl .+ p.qci)),
              ("u (m/s)", p.u), ("v (m/s)", p.v)]
    below = p.z .<= zmax
    for (j, (label, A)) in enumerate(panels)
        ax = Axis(fig[1, j]; xlabel = label, ylabel = j == 1 ? "z (km)" : "", limits = (nothing, (0, zmax / 1e3)))
        j > 1 && hideydecorations!(ax; grid = false)
        for n in ns
            nt = time_index(n, Nt)
            lines!(ax, A[below, nt], p.z[below] ./ 1e3; label = "$(round(p.t[nt]; digits = 2)) d")
        end
    end
    Legend(fig[1, length(panels) + 1], content(fig[1, 1]))
    return fig
end

"""
    plot_xz(s; j = 1, zmax = 16000)
    plot_xz(rundir, name; j = 1, n = last, zmax = 16000, kind = "fields", prefix = "monsoon_convection")

An x–z section at y index `j` of a snapshot `s` (from `read_snapshot` or `checkpoint_snapshot`), or of
variable `name` at time index `n` of `_fields.nc`.
"""
function plot_xz(s::NamedTuple; j = 1, zmax = 16_000)
    scale, units = display_units(s.name, s.units)
    A = scale .* s.data[:, j, :]
    below = s.z .<= zmax
    colormap, colorrange = s.name in ("u", "v", "w") ? (:balance, symmetric_range(A[:, below])) : (:viridis, Makie.automatic)
    fig = Figure(size = (1000, 450), fontsize = 14)
    ax = Axis(fig[1, 1]; xlabel = "x (km)", ylabel = "z (km)", limits = (nothing, (0, zmax / 1e3)),
              title = "$(s.name) ($units), y = $(round(s.y[j] / 1e3; digits = 1)) km, t = $(round(s.t; digits = 3)) d")
    hm = heatmap!(ax, s.x ./ 1e3, s.z ./ 1e3, A; colormap, colorrange)
    Colorbar(fig[1, 2], hm)
    return fig
end

plot_xz(rundir::AbstractString, name; j = 1, n = last, zmax = 16_000, kind = "fields", prefix = "monsoon_convection") =
    plot_xz(read_snapshot(rundir, name; kind, n, prefix); j, zmax)

"""
    plot_xy(s; z = 0)
    plot_xy(rundir, name; z = 0, n = last, kind = "surface", prefix = "monsoon_convection")

An x–y map at the level nearest height `z` (m) of a snapshot `s`, or of variable `name` at time
index `n` of `_surface.nc` (lowest level, hourly) or, with `kind = "fields"`, `_fields.nc`.
"""
function plot_xy(s::NamedTuple; z = 0)
    k = argmin(abs.(s.z .- z))
    scale, units = display_units(s.name, s.units)
    A = scale .* s.data[:, :, k]
    colormap, colorrange = s.name in ("u", "v", "w") ? (:balance, symmetric_range(A)) : (:viridis, Makie.automatic)
    fig = Figure(size = (1000, 550), fontsize = 14)
    ax = Axis(fig[1, 1]; xlabel = "x (km)", ylabel = "y (km)", aspect = DataAspect(),
              title = "$(s.name) ($units), z = $(round(Int, s.z[k])) m, t = $(round(s.t; digits = 3)) d")
    hm = heatmap!(ax, s.x ./ 1e3, s.y ./ 1e3, A; colormap, colorrange)
    Colorbar(fig[1, 2], hm)
    return fig
end

plot_xy(rundir::AbstractString, name; z = 0, n = last, kind = "surface", prefix = "monsoon_convection") =
    plot_xy(read_snapshot(rundir, name; kind, n, prefix); z)

"""
    animate_surface(rundir, file; name = "qv", framerate = 6, prefix = "monsoon_convection")

Movie (`file`, e.g. "qv_surface.mp4") of the hourly lowest-level maps of `name`, with a fixed
color range.
"""
function animate_surface(rundir, file; name = "qv", framerate = 6, prefix = "monsoon_convection")
    Nt = length(snapshot_times(rundir; kind = "surface", prefix))
    s = read_snapshot(rundir, name; kind = "surface", n = 1, prefix)
    scale, units = display_units(name, s.units)
    data, t = NCDataset(output_file(rundir, "surface"; prefix)) do ds
        scale .* read_var(ds, name)[:, :, 1, :], ds["time"].var[:] ./ day
    end
    colormap, colorrange = name in ("u", "v", "w") ? (:balance, symmetric_range(data)) : (:viridis, extrema(filter(isfinite, data)))
    n = Observable(1)
    fig = Figure(size = (1000, 550), fontsize = 14)
    ax = Axis(fig[1, 1]; xlabel = "x (km)", ylabel = "y (km)", aspect = DataAspect(),
              title = @lift("$name ($units), lowest level, t = $(round(t[$n]; digits = 3)) d"))
    hm = heatmap!(ax, s.x ./ 1e3, s.y ./ 1e3, @lift(data[:, :, $n]); colormap, colorrange)
    Colorbar(fig[1, 2], hm)
    record(fig, file, 1:Nt; framerate) do nn
        n[] = nn
    end
    return file
end

"""
    save_plots(rundir; outdir = joinpath(rundir, "plots"), prefix = "monsoon_convection")

Write the standard plots of a run as PNGs in `outdir`: time–height sections, profiles, lowest-level
qᵛ and w maps (last hour), x–z sections of w and qᵛ from the last 3D snapshot and from the latest
checkpoint. For the cluster, where there is no display.
"""
function save_plots(rundir; outdir = joinpath(rundir, "plots"), prefix = "monsoon_convection")
    mkpath(outdir)
    out(name) = joinpath(outdir, name)
    save(out("time_height.png"), plot_time_height(rundir; prefix))
    save(out("wind_time_height.png"), plot_wind_time_height(rundir; prefix))
    save(out("profiles.png"), plot_profiles(rundir; prefix))
    for name in ("qv", "w")
        save(out("surface_$name.png"), plot_xy(rundir, name; prefix))
        save(out("xz_$name.png"), plot_xz(rundir, name; prefix))
    end
    ck = read_checkpoint(rundir; prefix)
    save(out("checkpoint_xz_w.png"), plot_xz(checkpoint_snapshot(ck, :ρw)))
    save(out("checkpoint_xz_qv.png"), plot_xz(checkpoint_snapshot(ck, :ρqᵛ)))
    return outdir
end
