# Where are condensate fields negative in a checkpoint? Run from the repository directory:
#
#   julia --project helpers/negative_condensate.jl run/one-moment/monsoon_convection_checkpoint_iteration8980.jld2
#
# For each condensate field it prints the minimum specific value q = ρq/ρᵣ and where it is,
# the number of cells below -1e-6 kg/kg, the vertical distribution of the negatives, and the
# column through the rain minimum. CPU only; reads the checkpoint, does not build the model.

using MonsoonConvection
using MonsoonConvection: θ̄, q̄ᵗ, cm1_z_faces
using Breeze, Oceananigans
using Oceananigans.OutputWriters: JLD2   # not a direct dependency of this project
using Printf

const H = 5          # halo, as in build_model
const Δx = 500       # m, as in monsoon_convection.jl
const threshold = -1e-6

path = only(ARGS)
names, fields, clock = JLD2.jldopen(path, "r") do file
    names = Tuple(Symbol(n) for n in keys(file["simulation/model/fields"]))
    data = Dict(n => file["simulation/model/fields/$n/data"] for n in names)
    clock = [c => file["simulation/model/clock/$c"] for c in ("iteration", "time")
             if haskey(file, "simulation/model/clock/$c")]
    names, data, clock
end
println(path, ": ", join(("$c = $v" for (c, v) in clock), ", "))
println("fields: ", join(names, ", "))

# Vertical grid: a copy of stretched_top_faces in monsoon_convection.jl (keep them the same)
function stretched_top_faces(; z_stretch = 18000, z_top = 28000, Δz_top = 1000)
    lower = filter(≤(z_stretch), cm1_z_faces())
    Δz₀ = lower[end] - lower[end-1]
    L = z_top - lower[end]
    n = round(Int, 2L / (Δz₀ + Δz_top))
    Δz₁ = 2L / n - Δz₀
    Δz = [Δz₀ + (Δz₁ - Δz₀) * (i - 1) / (n - 1) for i in 1:n]
    faces = Float64.(vcat(lower, lower[end] .+ cumsum(Δz)))
    faces[end] = z_top
    return faces
end

# Reference density, as in build_model, on a single column
z_faces = stretched_top_faces(Δz_top = 1000)
Nz = length(z_faces) - 1
s = read_cm1_sounding(joinpath(@__DIR__, "..", "cm1", "input_sounding"))
column = RectilinearGrid(CPU(); size = Nz, z = z_faces, halo = H, topology = (Flat, Flat, Bounded))
reference_state = ReferenceState(column, ThermodynamicConstants();
                                 base_pressure = s.p₀,
                                 potential_temperature = z -> θ̄(s, z),
                                 vapor_mass_fraction = z -> q̄ᵗ(s, z))
ρᵣ = vec(interior(reference_state.density))
zᶜ = [(z_faces[k] + z_faces[k+1]) / 2 for k in 1:Nz]
size(first(values(fields)), 3) == Nz + 2H ||
    error("the checkpoint has $(size(first(values(fields)), 3) - 2H) levels, this script's grid $Nz")

specific(name) = (a = fields[name][H+1:end-H, H+1:end-H, H+1:end-H]; a ./ reshape(ρᵣ, 1, 1, :))

condensate = filter(n -> startswith(string(n), "ρq") && n ∉ (:ρqᵗ, :ρqᵉ, :ρqᵛ), names)
q = Dict(n => specific(n) for n in condensate)

for name in condensate
    f = q[name]
    m, I = findmin(f)
    i, j, k = Tuple(I)
    neg = f .< threshold
    @printf("\n%s: min %.3g g/kg at (i, j, k) = (%d, %d, %d), x = %.1f km, y = %.1f km, z = %.0f m; max %.3g g/kg\n",
            name, 1e3m, i, j, k, (i - 0.5) * Δx / 1e3, (j - 0.5) * Δx / 1e3, zᶜ[k], 1e3maximum(f))
    negative_path = sum(min.(f, 0) .* reshape(ρᵣ .* diff(z_faces), 1, 1, :)) / (size(f, 1) * size(f, 2))
    @printf("  %d cells below %.0e kg/kg, in %d columns; negative water %.3g kg m⁻² (domain mean)\n",
            count(neg), threshold, count(any(neg, dims = 3)), negative_path)
    any(neg) || continue
    println("  levels with negatives (k, z, count, min g/kg):")
    for kk in 1:Nz
        n = count(view(neg, :, :, kk))
        n > 0 && @printf("    %3d %7.0f m %8d %10.3g\n", kk, zᶜ[kk], n, 1e3minimum(view(f, :, :, kk)))
    end
end

# The column through the rain minimum, all condensate (g/kg) and the moisture prognostic
if :ρqʳ in condensate
    _, I = findmin(q[:ρqʳ])
    i, j, kmin = Tuple(I)
    moisture = filter(n -> n in (:ρqᵗ, :ρqᵉ, :ρqᵛ), names)
    columns = (condensate..., moisture...)
    vals = Dict(n => (n in condensate ? q[n] : specific(n)) for n in columns)
    println("\ncolumn (i, j) = ($i, $j) through the rain minimum, g/kg:")
    @printf("  %3s %7s", "k", "z (m)"); foreach(n -> @printf(" %10s", n), columns); println()
    for kk in max(1, kmin - 6):min(Nz, kmin + 6)
        @printf("  %3d %7.0f", kk, zᶜ[kk]); foreach(n -> @printf(" %10.4g", 1e3vals[n][i, j, kk]), columns)
        println(kk == kmin ? "   ← min" : "")
    end
end
