# Goal of this script is validate the convective parameterization that we will use.
# the first validation consists in measuring the mass added to the system by a convective event. This is based on Integrating equation 4 of
#Yang, D., and A. P. Ingersoll, 2013: Triggered Convection, Gravity Waves, and the MJO: A Shallow-Water Model. J. Atmos. Sci., 70, 2476–2486, https://doi.org/10.1175/JAS-D-12-0255.1.
# In which the mass added to the system after a convective event is equal to
# ΔH = 2/3 q0 (double check Argel!)



using DrWatson
@quickactivate "RamirezReyes_ShallowWaterInFPlane"

using Oceananigans
using Oceananigans.Models: ShallowWaterModel
using Printf
using CUDA
#using ProfileView


include(joinpath(@__DIR__,"../../src/convectiveparameterization.jl"))
include(joinpath(@__DIR__,"../../src/arrayutils.jl"))


architecture = CPU()
#Setup physicsl parameters

f = 0.0#5e-4 #5e-4
g = 0.0# 9.8
U = 50.0
Δη =  5.5#f * U / g

τ_c = 50
h_c = 40
heating_amplitude    = 1.0e9#1.0e9 #originally 9 for heating, -8 for cooling
radiative_cooling_rate = 0.0# 1.0e-8
convective_radius    = 20000.0
relaxation_parameter = 0#1.0/3600.0

#Setup domain

Lx, Ly = 1.0e5, 1.0e5
const Lz = 45
Nx, Ny = 512, 512

grid_spacing_x = Lx ÷ Nx
grid_spacing_y = Ly ÷ Ny

numelements_to_traverse_x = Int(convective_radius ÷ grid_spacing_x)
numelements_to_traverse_y = Int(convective_radius ÷ grid_spacing_y)


grid = RectilinearGrid(size = (Nx, Ny),
                            x = (0, Lx), y = (0, Ly),
                              topology = (Periodic, Periodic, Flat), halo = (max(numelements_to_traverse_x,3), max(numelements_to_traverse_y,3)))

@info "Built grid successfully"

isconvecting  = CenterField(architecture, grid)
convection_triggered_time  = CenterField(architecture, grid)

parameters = (; isconvecting = isconvecting, convection_triggered_time, τ_c, h_c, nghosts_x = numelements_to_traverse_x, nghosts_y = numelements_to_traverse_y, radiative_cooling_rate , q0 = heating_amplitude, R = convective_radius, relaxation_parameter)


#build forcing
convec_forcing = Forcing(model_forcing,discrete_form=true,parameters = parameters)
u_forcing = Forcing(u_damping, parameters=relaxation_parameter, field_dependencies=:u)
v_forcing = Forcing(v_damping, parameters=relaxation_parameter, field_dependencies=:v)

## Build the model

model = ShallowWaterModel(;timestepper=:RungeKutta3,
    advection=WENO5(grid=grid),
    grid=grid,
    gravitational_acceleration=g,
    coriolis=FPlane(f=f),
    forcing=(h=convec_forcing,u = u_forcing, v = v_forcing)
)


#Build background state and perturbations

#h̄(x, y, z) = model.grid.Lz +  Δη * tanh(y/Ly)*tanh(x/Lx)
#h̄(x, y, z) = model.grid.Lz -  Δη * exp(-((x-Lx/2)^2/(0.1*Lx)^2 + (y-Ly/2)^2/(0.1*Ly)^2 ))
function h̄(x, y, z)
    if x == grid.xᶜᵃᵃ[10] && y == grid.yᵃᶜᵃ[10]
        return 39
    else
        return Lz #-  Δη * exp(-((x-Lx/2)^2/(0.1*Lx)^2 + (y-Ly/2)^2/(0.1*Ly)^2 ))
    end
end
ū(x, y, z) = 0 #U * sech(y)^2
ω̄(x, y, z) = 0 #2 * U * sech(y)^2 * tanh(y)

small_amplitude = 1e-4

uⁱ(x, y, z) = ū(x, y, z) #+ small_amplitude * exp(-y^2) * randn()
hⁱ(x, y, z) = h̄(x, y, z)
uhⁱ(x, y, z) = 0.0 #uⁱ(x, y, z) * hⁱ(x, y, z)

uh, vh, h = model.solution

        u = ComputedField(uh / h)
        v = ComputedField(vh / h)
        ω = ComputedField(∂x(v) - ∂y(u))
ω_pert = ComputedField(ω - ω̄)

set!(model, uh = uhⁱ, h = hⁱ)


#Create the simulation
#simulation = Simulation(model, Δt = 1e-2, stop_time = 150)
simulation = Simulation(model, Δt = 1, stop_time = 600)

function update_convective_helper_arrays(sim, parameters = parameters)
    p = parameters
    #@info "Go run update_...!"
    m = sim.model
    update_convective_events!(m.architecture,p.isconvecting,p.convection_triggered_time,m.solution.h,
                              m.clock.time,p.τ_c,p.h_c,m.grid.Nx,m.grid.Ny, p.nghosts_x,p.nghosts_y)
    Oceananigans.BoundaryConditions.fill_halo_regions!(p.isconvecting, m.architecture)
    Oceananigans.BoundaryConditions.fill_halo_regions!(p.convection_triggered_time, m.architecture)
    #display(Array(p.convection_triggered_time.data.parent))
    #display(Array(p.isconvecting.data.parent))

end

function progress(sim)
    m = sim.model
    @info(@sprintf("Iter: %d, time: %.1f, Δt: %.3f, max|h|: %.2f",
                   m.clock.iteration, m.clock.time,
                   sim.Δt, maximum(abs, m.solution.h)))
    
end

simulation.callbacks[:progress] = Callback(progress, IterationInterval(1))
simulation.callbacks[:update_convective_helper_arrays] = Callback(update_convective_helper_arrays, IterationInterval(1))
#prepare output files
 simulation.output_writers[:fields] =
     NetCDFOutputWriter(
         model,
         (ω = ω, ω_pert = ω_pert, h = h , v = v , u = u),
         #filepath = joinpath(@__DIR__, "../../data/shallow_water_validation_cpu.nc"),
         filepath = joinpath(ENV["SCRATCH"], "shallow_water_validation_cpu.nc"),
         schedule = TimeInterval(1),
         mode = "c")

run!(simulation)
