# Readers for monsoon_convection.jl output, and a few helpers. The readers return plain arrays with
# their coordinates, so the notebook can compute with them (log10, 1e3 .* q, mean(A; dims = 1), ...)
# and plot with CairoMakie directly (Figure, Axis, heatmap!, Colorbar). Including this file only
# defines them.
#
# In plot_profs.ipynb and plots.ipynb, from the repository:
#     using Pkg; Pkg.activate("plots")
#     using Revise; includet("plotter.jl")
#     p = read_profiles("run/ekamsat-p3-ctl0")      # NamedTuple: p.t, p.z, p.qv, ... arrays
# The plots environment (plots/Project.toml) needs `Pkg.instantiate()` once on each machine.
#
# Output files (MonsoonConvection.build_simulation), "monsoon_convection" prefix:
#   _profiles.nc   horizontal means averaged over each hour, (z, time); also radiative_flux_divergence, w2
#   _surface.nc    hourly snapshots of the lowest level, (x, y, 1, time)
#   _fields.nc     3D snapshots, (x, y, z, time): daily (30 min in a small test)
#   _checkpoint_iteration<N>.jld2   the latest model state (ρ-weighted prognostic fields)
# Mass fractions (qv, qcl, ...) are kg/kg in the files and in the arrays read here: multiply by 1e3
# for g/kg. Times are in days, coordinates in m.

using CairoMakie, NCDatasets, JLD2, Statistics

# the readers and array helpers are in readers.jl (no plotting library, shared with diag.jl)
include("readers.jl")

# Font size of all figures; change it in a session with update_theme!(fontsize = 16)
set_theme!(fontsize = 20)

#####
##### Animation
#####

"""
    animate_surface(file, x, y, t, A; title = "", colormap = :viridis, colorrange = finite_range(A), framerate = 6)

Movie `file` (e.g. "qv_surface.mp4") of the maps `A[:, :, k]` (x, y, time) at times `t` (days); x and
y in m. For example, in g/kg:

    s = read_snapshot(rundir, "qv"; kind = "surface", n = :)
    animate_surface("qv_surface.mp4", s.x, s.y, s.t, 1e3 .* dropdims(s.data; dims = 3); title = "qv (g/kg)")
"""
function animate_surface(file, x, y, t, A; title = "", colormap = :viridis, colorrange = finite_range(A), framerate = 6)
    n = Observable(1)
    fig = Figure(size = (1000, 550))
    ax = Axis(fig[1, 1]; xlabel = "x (km)", ylabel = "y (km)", aspect = DataAspect(),
              title = @lift("$title, t = $(round(t[$n]; digits = 3)) d"))
    hm = heatmap!(ax, x ./ 1e3, y ./ 1e3, @lift(A[:, :, $n]); colormap, colorrange)
    Colorbar(fig[1, 2], hm)
    record(fig, file, 1:size(A, 3); framerate) do k
        n[] = k
    end
    return file
end
