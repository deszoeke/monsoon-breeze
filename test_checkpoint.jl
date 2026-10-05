using Breeze, Oceananigans.Units, CairoMakie
using UnicodePlots

grid = RectilinearGrid(CPU(); size=(256, 256), x=(-10e3, 10e3), z=(0, 10e3),
                       topology=(Periodic, Flat, Bounded))

reference = ReferenceState(grid; potential_temperature=300)
model = AtmosphereModel(grid; dynamics=AnelasticDynamics(reference), advection=WENO(order=5))
set!(model, θ = (x, z) -> 300 + 2cos(π/2 * min(1, √(x^2 + (z - 2000)^2) / 2000))^2)

simulation = Simulation(model; Δt=2, stop_time=25minutes)
# Add a Checkpointer to the simulation's output writers
simulation.output_writers[:checkpointer] = Checkpointer(
    model, 
    schedule = TimeInterval(5minutes), # Write a checkpoint every 5 mins of simulation time
    prefix = "breeze_checkpoint",       # Name of the output file prefix
    cleanup = true                      # Keeps only the most recent checkpoint file to save disk space
)

conjure_time_step_wizard!(simulation, cfl=0.7)
run!(simulation)

UnicodePlots.heatmap(liquid_ice_potential_temperature(model).data[1:256,1,1:256]')
UnicodePlots.heatmap(liquid_ice_potential_temperature(model).data[128:256,1,128:256]')
#heatmap(liquid_ice_potential_temperature(model), colormap=:thermal, axis=(; aspect=2))

# to restart and run the simulation further

# pickup=true restores from the latest "breeze_checkpoint_iteration*.jld2" in the working directory
simulation.stop_time = 50minutes
run!(simulation, pickup=true)
UnicodePlots.heatmap(liquid_ice_potential_temperature(model).data[128:256,1,128:256]')
