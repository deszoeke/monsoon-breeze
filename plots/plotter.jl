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

# Font size of all figures; change it in a session with update_theme!(fontsize = 16)
set_theme!(fontsize = 20)

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
name (T, theta, qv, qcl, qci, qr, qsn, u, v, w, w2, radiative_flux_divergence, ...; P3: qi, qf, ...),
plus `w_rms` = √w2 and `qc` = qcl + cloud ice (qci, or qi in P3).
"""
function read_profiles(rundir; prefix = "monsoon_convection")
    p = NCDataset(output_file(rundir, "profiles"; prefix)) do ds
        names = [k for k in keys(ds) if k != "time" && "time" in dimnames(ds[k])]
        merge((; t = ds["time"].var[:] ./ day, x = ds["x_caa"][:], y = ds["y_aca"][:],
                 z = ds["z_aac"][:], zᶠ = ds["z_aaf"][:]),
              NamedTuple(Symbol(k) => read_var(ds, k) for k in names))
    end
    ice = haskey(p, :qci) ? :qci : :qi
    return merge(p, (; w_rms = sqrt.(max.(p.w2, 0)), qc = p.qcl .+ p[ice]))
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

function finite_range(A)
    a = filter(isfinite, A)
    isempty(a) && return (0, 1)
    lo, hi = extrema(a)
    return lo < hi ? (lo, hi) : (lo - 1, hi + 1)
end

# A function f of a variable: the plot methods with a first argument f, e.g.
# plot_xz(log10, rundir, "qv"), plot f of the values in display units (g/kg for mass fractions),
# elementwise. Non-finite results (log10(0) = -Inf) are left blank. f must accept every value:
# for logs of mass fractions, which can be slightly negative, use f(q) = log10(max(q, 1e-6)).
apply_finite(f, A) = map(x -> (y = f(x); isfinite(y) ? y : oftype(y, NaN)), A)

# Label of f(variable): identity is the plain variable. Name f (f(q) = ..., not q -> ...) for a
# readable label.
labelled(::typeof(identity), name, units) = "$name ($units)"
labelled(f, name, units) = "$f($name), $name in $units"

# Color scale: velocities symmetric about 0; anything else, and any f of a variable, the data range
color_scale(::typeof(identity), name, A) =
    name in ("u", "v", "w") ? (:balance, symmetric_range(A)) : (:viridis, finite_range(A))
color_scale(f, name, A) = (:viridis, finite_range(A))

# Profile references for anomalies: the first output, or the time mean
first_profile(A) = A[:, 1:1]
time_mean(A) = mean(A; dims = 2)

#####
##### Profile plots: building blocks that draw into an Axis, and figures made of them
#####

# Units of profile variables that aren't mass fractions (those display in g/kg)
const profile_units = Dict("T" => "K", "theta" => "K", "u" => "m/s", "v" => "m/s", "w" => "m/s",
                           "w_rms" => "m/s", "radiative_flux_divergence" => "W/m³")

# Rows of a profile array are on z faces (w, w2, w_rms) or at cell centers
vertical_coordinate(p, A) = size(A, 1) == length(p.z) ? p.z : p.zᶠ

# A keyword left at Makie.automatic takes the default
or_default(::Makie.Automatic, default) = default
or_default(given, default) = given

# A profile array as its anomaly from `reference` (first_profile, time_mean), or as it is (nothing)
anomaly(::Nothing, A) = A
anomaly(reference::Function, A) = A .- reference(A)

anomaly_note(::Nothing, p) = ""
anomaly_note(::typeof(first_profile), p) = "change since t = $(round(p.t[1]; digits = 2)) d"
anomaly_note(::typeof(time_mean), p) = "anomaly from the time mean"
anomaly_note(reference, p) = "anomaly"

# In multi-panel plots f applies to the mass-fraction panels only, and a reference to T and qv only
panel_function(f, name) = startswith(name, "q") ? f : identity
reference_for(reference, name) = name in ("T", "qv") ? reference : nothing

# The four condensate panels: one-moment (cloud liquid, cloud ice, rain, snow) or P3 (cloud liquid,
# total ice, rain, rime) output
condensate_names(p) = haskey(p, :qsn) ? ("qcl", "qci", "qr", "qsn") : ("qcl", "qi", "qr", "qf")

# Colors of a profile variable: anomalies and signed variables symmetric about 0, else the data range
profile_colors(f, ::Function, name, A) = (:balance, symmetric_range(A))
profile_colors(::typeof(identity), ::Nothing, name, A) =
    name in ("u", "v", "w", "radiative_flux_divergence") ? (:balance, symmetric_range(A)) : (:dense, finite_range(A))
profile_colors(f, ::Nothing, name, A) = (:dense, finite_range(A))

"""
    profile_label(f, p, name; reference = nothing)

Label of profile variable `name` (a string, as in `read_profiles`) in display units, e.g. "qv (g/kg),
change since t = 2.04 d".
"""
function profile_label(f::Function, p, name; reference = nothing)
    name = string(name)
    scale, units = display_units(name, get(profile_units, name, ""))
    join(filter(!isempty, [labelled(f, name, units), anomaly_note(reference, p)]), ", ")
end

"""
    profile_field(f, p, name; reference = nothing, zmax = 12000)

Profile variable `name` of `p` (from `read_profiles`) as plotted: `(; t, z, A, label)` with `A` (z, time)
in display units, f of the anomaly from `reference` (`first_profile`, `time_mean`; `nothing` for the
values), and `z` up to `zmax` (m).
"""
function profile_field(f::Function, p, name; reference = nothing, zmax = 12_000)
    name = string(name)
    A = getproperty(p, Symbol(name))
    z = vertical_coordinate(p, A)
    below = z .<= zmax
    scale, units = display_units(name, get(profile_units, name, ""))
    return (; t = p.t, z = z[below], A = apply_finite(f, scale .* anomaly(reference, A)[below, :]),
            label = profile_label(f, p, name; reference))
end

"""
    time_height!(ax, p, name; reference = nothing, zmax = 12000, colormap, colorrange)
    time_height!(f, ax, p, name; ...)

Draw the time–height section of profile variable `name` (a string: "T", "qv", "qcl", "w_rms", ...;
`p` from `read_profiles`) into the Axis `ax`, and return the heatmap. With `f` (e.g. log10), f of
the values in display units. With `reference` (`first_profile`, `time_mean`), the anomaly from it.
`colormap` and `colorrange` default to a scale from the data; give the same `colorrange` to compare
panels (or use `compare_time_height`). Axis title, labels and a `Colorbar` are the caller's:

    fig = Figure(); ax = Axis(fig[1, 1]; title = "qv", ylabel = "z (km)")
    hm = time_height!(ax, read_profiles(rundir), "qv"; reference = first_profile)
    Colorbar(fig[1, 2], hm)
"""
function time_height!(f::Function, ax, p::NamedTuple, name; reference = nothing, zmax = 12_000,
                      colormap = Makie.automatic, colorrange = Makie.automatic)
    s = profile_field(f, p, name; reference, zmax)
    default_map, default_range = profile_colors(f, reference, string(name), s.A)
    xlims!(ax, extrema(s.t)...)
    ylims!(ax, 0, zmax / 1e3)
    return heatmap!(ax, s.t, s.z ./ 1e3, permutedims(s.A);
                    colormap = or_default(colormap, default_map), colorrange = or_default(colorrange, default_range))
end

time_height!(ax, p::NamedTuple, name; kw...) = time_height!(identity, ax, p, name; kw...)

# The 0 °C level of the mean T (dashed)
freezing_level!(ax, p) =
    contour!(ax, p.t, p.z ./ 1e3, permutedims(p.T); levels = [273.15], color = :black, linestyle = :dash)

"""
    plot_axes(fig)

The axes of a figure in the order they were made (colorbars and legends left out): top to bottom,
then left to right. Set limits on one and redisplay the figure:

    fig = plot_time_height(rundir)
    ax = plot_axes(fig)[2]
    xlims!(ax, 1, 2)        # days
    ylims!(ax, 0, 5)        # km
    fig

Time–height panels share the time axis, so `xlims!` on one sets them all (in a comparison, those of
one column). Heights are in km and times in days, as on the axes.
"""
plot_axes(fig) = filter(c -> c isa Axis, fig.content)

# One run's variables stacked in a column of time–height panels, a colorbar each
function stacked_time_height(f::Function, p, names; reference = nothing, zmax, figsize)
    fig = Figure(size = figsize)
    axes = map(enumerate(names)) do (i, name)
        g, r = panel_function(f, name), reference_for(reference, name)
        ax = Axis(fig[i, 1]; ylabel = "z (km)")
        Colorbar(fig[i, 2], time_height!(g, ax, p, name; reference = r, zmax))
        title = profile_label(g, p, name; reference = r)
        if name in condensate_names(p)
            freezing_level!(ax, p)
            title *= ", dashed: 0 °C"
        end
        ax.title = title
        ax
    end
    foreach(ax -> hidexdecorations!(ax; grid = false), axes[1:end-1])
    axes[end].xlabel = "time (days)"
    linkxaxes!(axes...)
    return fig
end

"""
    plot_time_height(rundir; zmax = 12000, reference = first_profile, prefix = "monsoon_convection")
    plot_time_height(f, rundir; ...)

`f` (e.g. log10) applies to the four condensate panels, in g/kg.

Time–height sections of the horizontal means: T and qᵛ anomalies from `reference` (`first_profile`,
the first hourly mean, or `time_mean`), four condensates (each with the 0 °C level of the mean T),
and radiative flux divergence (positive: cooling). Panels from `plot_axes(fig)`: 1 T, 2 qv, then
`condensate_names` (one-moment: qcl, qci, qr, qsn; P3: qcl, qi, qr, qf), 7 radiation.
"""
plot_time_height(rundir; kw...) = plot_time_height(identity, rundir; kw...)

function plot_time_height(f::Function, rundir; zmax = 12_000, reference = first_profile, prefix = "monsoon_convection")
    p = read_profiles(rundir; prefix)
    names = ["T", "qv", condensate_names(p)..., "radiative_flux_divergence"]
    return stacked_time_height(f, p, names; reference, zmax, figsize = (900, 1700))
end

"""
    plot_wind_time_height(rundir; zmax = 20000, prefix = "monsoon_convection")

Time–height sections of the horizontal-mean u and v, and the rms vertical velocity √⟨w²⟩.
"""
plot_wind_time_height(rundir; zmax = 20_000, prefix = "monsoon_convection") =
    stacked_time_height(identity, read_profiles(rundir; prefix), ["u", "v", "w_rms"]; zmax, figsize = (900, 750))

"""
    compare_time_height(runs, names; labels, reference = nothing, zmax = 12000, prefix = "monsoon_convection")
    compare_time_height(f, runs, names; ...)

Time–height sections of the variables `names` (strings: "T", "qv", "qr", ...; rows) in each of `runs`
(columns): run directories, or profiles from `read_profiles`. `labels` title the columns (default
the directory names). The runs of a row share a color scale and a colorbar. `reference`
(`first_profile`, `time_mean`) plots anomalies from each run's own reference, of every variable.
`f` (e.g. log10) applies to the mass-fraction variables only. Panels from `plot_axes(fig)`: column by
column, so panel `(i, j)` of `nrows` rows is `(j - 1) * nrows + i`.

    fig = compare_time_height(rundirs, ["qv", "T"]; reference = first_profile)
"""
compare_time_height(runs, names; kw...) = compare_time_height(identity, runs, names; kw...)

compare_time_height(f::Function, rundirs::AbstractVector{<:AbstractString}, names;
                    labels = basename.(rundirs), prefix = "monsoon_convection", kw...) =
    compare_time_height(f, [read_profiles(d; prefix) for d in rundirs], names; labels, kw...)

function compare_time_height(f::Function, ps::AbstractVector{<:NamedTuple}, names; labels = string.(eachindex(ps)),
                             reference = nothing, zmax = 12_000,
                             figsize = (350 * length(ps) + 200, 250 * length(names)))
    names = string.(names)
    nrows, ncols = length(names), length(ps)
    fig = Figure(size = figsize)
    axes = [Axis(fig[i, j]; title = i == 1 ? labels[j] : "", ylabel = j == 1 ? "z (km)" : "")
            for i in 1:nrows, j in 1:ncols]
    for (i, name) in enumerate(names)
        g = panel_function(f, name)
        A = reduce(vcat, [vec(profile_field(g, p, name; reference, zmax).A) for p in ps])
        colormap, colorrange = profile_colors(g, reference, name, A)
        hm = nothing
        for (j, p) in enumerate(ps)
            hm = time_height!(g, axes[i, j], p, name; reference, zmax, colormap, colorrange)
        end
        Colorbar(fig[i, ncols + 1], hm; label = profile_label(g, ps[1], name; reference))
    end
    foreach(ax -> hidexdecorations!(ax; grid = false), axes[1:end-1, :])
    foreach(ax -> hideydecorations!(ax; grid = false), axes[:, 2:end])
    foreach(ax -> ax.xlabel = "time (days)", axes[end, :])
    linkyaxes!(axes...)
    foreach(j -> linkxaxes!(axes[:, j]...), 1:ncols)
    return fig
end

# The label of a profile line: the time of the profile, or a given label (a run's name)
line_label(::Nothing, p, nt) = "$(round(p.t[nt]; digits = 2)) d"
line_label(label, p, nt) = label

"""
    profile!(ax, p, name; ns = (first, last), zmax = 16000, label = nothing)
    profile!(f, ax, p, name; ...)

Draw the horizontal-mean profile of variable `name` (a string, as in `read_profiles`) at the hourly
means `ns` (indices, or `first`/`last`) into the Axis `ax` as lines, in display units, or f of them.
Lines are labelled by their time, or by `label`. Returns `ax`.
"""
function profile!(f::Function, ax, p::NamedTuple, name; ns = (first, last), zmax = 16_000, label = nothing)
    name = string(name)
    A = getproperty(p, Symbol(name))
    z = vertical_coordinate(p, A)
    below = z .<= zmax
    scale, units = display_units(name, get(profile_units, name, ""))
    for n in ns
        nt = time_index(n, length(p.t))
        lines!(ax, apply_finite(f, scale .* A[below, nt]), z[below] ./ 1e3; label = line_label(label, p, nt))
    end
    ylims!(ax, 0, zmax / 1e3)
    return ax
end

profile!(ax, p::NamedTuple, name; kw...) = profile!(identity, ax, p, name; kw...)

# A row of axes, one per variable, labelled in display units; y axis on the first only
function profile_axes(fig, f::Function, p, names)
    axes = [Axis(fig[1, j]; xlabel = profile_label(panel_function(f, name), p, name),
                 ylabel = j == 1 ? "z (km)" : "", xticks = WilkinsonTicks(3)) for (j, name) in enumerate(names)]
    foreach(ax -> hideydecorations!(ax; grid = false), axes[2:end])
    return axes
end

"""
    plot_profiles(rundir; ns = (first, last), zmax = 16000, prefix = "monsoon_convection")
    plot_profiles(f, rundir; ...)

Horizontal-mean θ, qᵛ, cloud condensate (qc: cloud liquid + ice), u and v at the hourly means `ns`
(indices, or `first`/`last`). `f` (e.g. log10) applies to the qᵛ and condensate panels, in g/kg.
"""
plot_profiles(rundir; kw...) = plot_profiles(identity, rundir; kw...)

function plot_profiles(f::Function, rundir; ns = (first, last), zmax = 16_000, prefix = "monsoon_convection")
    p = read_profiles(rundir; prefix)
    names = ["theta", "qv", "qc", "u", "v"]
    fig = Figure(size = (1500, 600))
    axes = profile_axes(fig, f, p, names)
    for (ax, name) in zip(axes, names)
        profile!(panel_function(f, name), ax, p, name; ns, zmax)
    end
    Legend(fig[1, length(names) + 1], content(fig[1, 1]))
    return fig
end

"""
    compare_profiles(runs, names; labels, n = last, zmax = 16000, prefix = "monsoon_convection")
    compare_profiles(f, runs, names; ...)

Horizontal-mean profiles of the variables `names` (strings, one panel each) at time index `n` (an
index, or `first`/`last`) of each of `runs` (run directories, or profiles from `read_profiles`), one
line per run, labelled by `labels` (default the directory names). `f` (e.g. log10) applies to the
mass-fraction variables only.

    fig = compare_profiles(rundirs, ["theta", "qv", "qr"])
"""
compare_profiles(runs, names; kw...) = compare_profiles(identity, runs, names; kw...)

compare_profiles(f::Function, rundirs::AbstractVector{<:AbstractString}, names;
                 labels = basename.(rundirs), prefix = "monsoon_convection", kw...) =
    compare_profiles(f, [read_profiles(d; prefix) for d in rundirs], names; labels, kw...)

function compare_profiles(f::Function, ps::AbstractVector{<:NamedTuple}, names; labels = string.(eachindex(ps)),
                          n = last, zmax = 16_000)
    names = string.(names)
    fig = Figure(size = (250 * length(names) + 250, 600))
    axes = profile_axes(fig, f, ps[1], names)
    for (ax, name) in zip(axes, names), (p, label) in zip(ps, labels)
        profile!(panel_function(f, name), ax, p, name; ns = (n,), zmax, label)
    end
    Legend(fig[1, length(names) + 1], content(fig[1, 1]))
    return fig
end

#####
##### x–z and x–y sections
#####

"""
    xz!(ax, s; j = 1, zmax = 16000, colormap, colorrange)
    xz!(f, ax, s; ...)

Draw the x–z section at y index `j` of snapshot `s` (from `read_snapshot` or `checkpoint_snapshot`) into
the Axis `ax`, with title and axis labels, and return the heatmap. With `f` (e.g. log10), f of the
variable. `colormap` and `colorrange` default to a scale from the data; give the same `colorrange` to
compare panels. The `Colorbar` is the caller's.
"""
function xz!(f::Function, ax, s::NamedTuple; j = 1, zmax = 16_000,
             colormap = Makie.automatic, colorrange = Makie.automatic)
    scale, units = display_units(s.name, s.units)
    A = apply_finite(f, scale .* s.data[:, j, :])
    default_map, default_range = color_scale(f, s.name, A[:, s.z .<= zmax])
    ax.title = "$(labelled(f, s.name, units)), y = $(round(s.y[j] / 1e3; digits = 1)) km, t = $(round(s.t; digits = 3)) d"
    ax.xlabel = "x (km)"
    ax.ylabel = "z (km)"
    ylims!(ax, 0, zmax / 1e3)
    return heatmap!(ax, s.x ./ 1e3, s.z ./ 1e3, A;
                    colormap = or_default(colormap, default_map), colorrange = or_default(colorrange, default_range))
end

xz!(ax, s::NamedTuple; kw...) = xz!(identity, ax, s; kw...)

"""
    xy!(ax, s; z = 0, colormap, colorrange)
    xy!(f, ax, s; ...)

Draw the x–y map at the level nearest height `z` (m) of snapshot `s` into the Axis `ax`, with title and
axis labels, and return the heatmap. With `f` (e.g. log10), f of the variable. `colormap` and
`colorrange` default to a scale from the data. The `Colorbar` is the caller's.
"""
function xy!(f::Function, ax, s::NamedTuple; z = 0, colormap = Makie.automatic, colorrange = Makie.automatic)
    k = argmin(abs.(s.z .- z))
    scale, units = display_units(s.name, s.units)
    A = apply_finite(f, scale .* s.data[:, :, k])
    default_map, default_range = color_scale(f, s.name, A)
    ax.title = "$(labelled(f, s.name, units)), z = $(round(Int, s.z[k])) m, t = $(round(s.t; digits = 3)) d"
    ax.xlabel = "x (km)"
    ax.ylabel = "y (km)"
    ax.aspect = DataAspect()
    return heatmap!(ax, s.x ./ 1e3, s.y ./ 1e3, A;
                    colormap = or_default(colormap, default_map), colorrange = or_default(colorrange, default_range))
end

xy!(ax, s::NamedTuple; kw...) = xy!(identity, ax, s; kw...)

"""
    plot_xz(s; j = 1, zmax = 16000)
    plot_xz(rundir, name; j = 1, n = last, zmax = 16000, kind = "fields", prefix = "monsoon_convection")
    plot_xz(f, s; ...), plot_xz(f, rundir, name; ...)

An x–z section at y index `j` of a snapshot `s` (from `read_snapshot` or `checkpoint_snapshot`), or of
variable `name` at time index `n` of `_fields.nc`. With `f` (e.g. log10), of f of the variable.
"""
plot_xz(s::NamedTuple; kw...) = plot_xz(identity, s; kw...)

function plot_xz(f::Function, s::NamedTuple; j = 1, zmax = 16_000)
    fig = Figure(size = (1000, 450))
    Colorbar(fig[1, 2], xz!(f, Axis(fig[1, 1]), s; j, zmax))
    return fig
end

plot_xz(rundir::AbstractString, name; kw...) = plot_xz(identity, rundir, name; kw...)

plot_xz(f::Function, rundir::AbstractString, name; j = 1, n = last, zmax = 16_000, kind = "fields",
        prefix = "monsoon_convection") =
    plot_xz(f, read_snapshot(rundir, name; kind, n, prefix); j, zmax)

"""
    plot_xy(s; z = 0)
    plot_xy(rundir, name; z = 0, n = last, kind = "surface", prefix = "monsoon_convection")
    plot_xy(f, s; ...), plot_xy(f, rundir, name; ...)

An x–y map at the level nearest height `z` (m) of a snapshot `s`, or of variable `name` at time
index `n` of `_surface.nc` (lowest level, hourly) or, with `kind = "fields"`, `_fields.nc`. With `f`
(e.g. log10), of f of the variable.
"""
plot_xy(s::NamedTuple; kw...) = plot_xy(identity, s; kw...)

function plot_xy(f::Function, s::NamedTuple; z = 0)
    fig = Figure(size = (1000, 550))
    Colorbar(fig[1, 2], xy!(f, Axis(fig[1, 1]), s; z))
    return fig
end

plot_xy(rundir::AbstractString, name; kw...) = plot_xy(identity, rundir, name; kw...)

plot_xy(f::Function, rundir::AbstractString, name; z = 0, n = last, kind = "surface", prefix = "monsoon_convection") =
    plot_xy(f, read_snapshot(rundir, name; kind, n, prefix); z)

"""
    animate_surface(rundir, file; name = "qv", framerate = 6, prefix = "monsoon_convection")
    animate_surface(f, rundir, file; ...)

Movie (`file`, e.g. "qv_surface.mp4") of the hourly lowest-level maps of `name` (or of f of it), with
a fixed color range.
"""
animate_surface(rundir, file; kw...) = animate_surface(identity, rundir, file; kw...)

function animate_surface(f::Function, rundir, file; name = "qv", framerate = 6, prefix = "monsoon_convection")
    Nt = length(snapshot_times(rundir; kind = "surface", prefix))
    s = read_snapshot(rundir, name; kind = "surface", n = 1, prefix)
    scale, units = display_units(name, s.units)
    data, t = NCDataset(output_file(rundir, "surface"; prefix)) do ds
        apply_finite(f, scale .* read_var(ds, name)[:, :, 1, :]), ds["time"].var[:] ./ day
    end
    colormap, colorrange = color_scale(f, name, data)
    label = labelled(f, name, units)
    n = Observable(1)
    fig = Figure(size = (1000, 550))
    ax = Axis(fig[1, 1]; xlabel = "x (km)", ylabel = "y (km)", aspect = DataAspect(),
              title = @lift("$label, lowest level, t = $(round(t[$n]; digits = 3)) d"))
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
