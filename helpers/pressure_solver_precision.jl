# Run the anelastic pressure solve in its own floating-point precision, independent of the
# model's (e.g. a Float32 model with a Float64 pressure solve). Included by monsoon_convection.jl
# when --pressure_solver differs from --float; not run directly.
#
# Why: the Fourier–tridiagonal pressure solve is poorly conditioned for the longest horizontal
# waves under a tall, strongly stratified anelastic column. On the 512 km domain a Float32 solve
# is unstable (a domain-scale mode grows in the top cell), while a Float64 solve with an otherwise
# Float32 model is stable and matches an all-Float64 run (see README, "Changes to Breeze
# defaults", and breeze_issue_pressure_precision.md).
#
# How: this REDEFINES Breeze's `dynamics_pressure_solver(::AnelasticDynamics, grid)` for this
# Julia session, building the same solver on a copy of the grid in the requested precision. It
# relies on Breeze internals (checked against Breeze 0.11.3) and is a stopgap until Breeze offers
# such an option itself. It cannot live in the MonsoonConvection package: packages may not
# redefine another package's methods while precompiling.

using Breeze, Oceananigans
using Breeze.AnelasticEquations: AnelasticDynamics, AnelasticTridiagonalSolverFormulation
using Oceananigans.Solvers: FourierTridiagonalPoissonSolver
using Oceananigans.Grids: znodes, topology, halo_size
using Oceananigans.Architectures: architecture

pkgversion(Breeze) == v"0.11.3" ||
    @warn "helpers/pressure_solver_precision.jl was written against Breeze 0.11.3; found $(pkgversion(Breeze)). Check that dynamics_pressure_solver is unchanged."

const pressure_solver_float_type = Ref{DataType}(Float64)

function Breeze.AtmosphereModels.dynamics_pressure_solver(dynamics::AnelasticDynamics, grid)
    FT = pressure_solver_float_type[]
    solver_grid = RectilinearGrid(architecture(grid), FT;
                                  size = size(grid), halo = halo_size(grid), topology = topology(grid),
                                  x = (0, grid.Lx), y = (0, grid.Ly), z = Array(znodes(grid, Face())))
    ρᵣ = Field{Nothing, Nothing, Center}(solver_grid)                    # reference density in FT
    set!(ρᵣ, Array(interior(dynamics.reference_state.density)))
    formulation = AnelasticTridiagonalSolverFormulation(ρᵣ)
    @info "Pressure solver in $FT (model in $(eltype(grid)))"
    return FourierTridiagonalPoissonSolver(solver_grid; tridiagonal_formulation = formulation)
end
