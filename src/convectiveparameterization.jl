"""
    update_convective_events!(architecture,isconvecting,convection_triggered_time,h,t,τ_convec,h_threshold,Nx,Ny)
Use the parameters τ_convec (field of times since last convective event started) and h_threshold to determine if one point should convect.
The version that receives architecture as first parameter is an interface for the specific implementation.

Based on:
Yang, D., and A. P. Ingersoll, 2013: Triggered Convection, Gravity Waves, and the MJO: A Shallow-Water Model. J. Atmos. Sci., 70, 2476–2486, https://doi.org/10.1175/JAS-D-12-0255.1.
"""
function update_convective_events!(architecture :: CPU,isconvecting,convection_triggered_time,h,t,τ_convec,h_threshold,Nx,Ny, boundary_layer = false)
    update_convective_events_cpu!(isconvecting,convection_triggered_time,h,t,τ_convec,h_threshold, boundary_layer)
end

"""
    update_convective_events!(architecture,isconvecting,convection_triggered_time,h,t,τ_convec,h_threshold,Nx,Ny)
Use the parameters τ_convec (field of times since last convective event started) and h_threshold to determine if one point should convect.
The version that receives architecture as first parameter is an interface for the specific implementation.

Based on:
Yang, D., and A. P. Ingersoll, 2013: Triggered Convection, Gravity Waves, and the MJO: A Shallow-Water Model. J. Atmos. Sci., 70, 2476–2486, https://doi.org/10.1175/JAS-D-12-0255.1.
"""
function update_convective_events!(architecture :: GPU,isconvecting,convection_triggered_time,h,t,τ_convec,h_threshold,Nx,Ny, boundary_layer = true)
    kernel = @cuda launch=false update_convective_events_gpu!(isconvecting,convection_triggered_time,h,t,τ_convec,h_threshold,Nx,Ny,boundary_layer)
    config = launch_configuration(kernel.fun)
    threads = min(size(isconvecting,1), config.threads)
    blocks = cld(size(isconvecting,1), threads)
    CUDA.@sync begin
        kernel(isconvecting,convection_triggered_time,h,t,τ_convec,h_threshold,Nx,Ny,boundary_layer; threads, blocks)
    end
end

"""
    update_convective_events_cpu!(isconvecting,convection_triggered_time,h,t,τ_convec,h_threshold,Nx,Ny)
Use the parameters τ_convec (field of times since last convective event started) and h_threshold to determine if one point should convect.
The version contains the implementation for CPU.

Based on:
Yang, D., and A. P. Ingersoll, 2013: Triggered Convection, Gravity Waves, and the MJO: A Shallow-Water Model. J. Atmos. Sci., 70, 2476–2486, https://doi.org/10.1175/JAS-D-12-0255.1.
"""
@inline function update_convective_events_cpu!(isconvecting,convection_triggered_time,h,t,τ_convec,h_threshold, boundary_layer = false)
        compare = boundary_layer ? (>=) : (<=)
        int_h = interior(h)
        int_isconvecting = interior(isconvecting)
        int_convection_triggered_time = interior(convection_triggered_time)
    @tturbo for ind in eachindex(int_h)
        time_convecting = t - int_convection_triggered_time[ind]
        needs_to_convect_by_time = int_isconvecting[ind] * (time_convecting < τ_convec) #has been convecting less than τ_c?
        needs_to_convect_by_height = compare(int_h[ind], h_threshold)
        will_start_convecting = needs_to_convect_by_height * iszero(needs_to_convect_by_time) #time needs be updated?
       
        needs_to_convect = needs_to_convect_by_time | needs_to_convect_by_height
        int_isconvecting[ind] = needs_to_convect
        int_convection_triggered_time[ind] = ifelse(will_start_convecting, t, int_convection_triggered_time[ind])
    end
    return nothing
end

"""
    update_convective_events_gpu!(isconvecting,convection_triggered_time,h,t,τ_convec,h_threshold,Nx,Ny)
Use the parameters τ_convec (field of times since last convective event started) and h_threshold to determine if one point should convect.
The version contains the implementation for GPU using CUDA.

Based on:
Yang, D., and A. P. Ingersoll, 2013: Triggered Convection, Gravity Waves, and the MJO: A Shallow-Water Model. J. Atmos. Sci., 70, 2476–2486, https://doi.org/10.1175/JAS-D-12-0255.1.
"""
function update_convective_events_gpu!(isconvecting,convection_triggered_time,h,t,τ_convec,h_threshold,Nx,Ny, boundary_layer = false)
    #@show typeof(h)

    compare = boundary_layer ? (>=) : (<=)

    index_x = (blockIdx().x - 1) * blockDim().x + threadIdx().x
    stride_x = gridDim().x * blockDim().x

    index_y = (blockIdx().y - 1) * blockDim().y + threadIdx().y
    stride_y = gridDim().y * blockDim().y

    
    @inbounds for i in index_x:stride_x:Nx
        for j in index_y:stride_y:Ny
            time_convecting = t - convection_triggered_time[i,j]
            needs_to_convect_by_time = isconvecting[i,j] && (time_convecting < τ_convec) #has been convecting less than τ_c?
            needs_to_convect_by_height = compare(h[i,j] , h_threshold)
            will_start_convecting = needs_to_convect_by_height && iszero(needs_to_convect_by_time) #time needs be updated?
            isconvecting[i,j] = needs_to_convect_by_time || needs_to_convect_by_height 
            will_start_convecting && (convection_triggered_time[i,j] = t) #Update time only if new convective event
        end
    end
    
    return nothing
end

"""
    heat(t,distance_from_conv_centersq,conv_time_triggered,q0,τ_c,R2,A0)
For a point that will be heated by convection, compute the value of the convective mass source.

Based on:
Yang, D., and A. P. Ingersoll, 2013: Triggered Convection, Gravity Waves, and the MJO: A Shallow-Water Model. J. Atmos. Sci., 70, 2476–2486, https://doi.org/10.1175/JAS-D-12-0255.1.
"""
@inline function heat(t,conv_time_triggered,τ_c,heat_from_stencil)
    deltat   = t - conv_time_triggered
    quotient = 2.0 * (deltat - τ_c/2.0)/(τ_c)
    q        = heat_from_stencil*(1.0 - quotient*quotient)
    return  q / τ_c
end

"""
    nth_neighbor(i,n,N) = mod1(i + n,N)
Tells you the index of your nth neighbor considering periodic boundaries.
"""
@inline nth_neighbor(i,n,N) = mod1(i + n,N)

"""
    heat_at_point(i,j,k,clock,τ_c,convective_radius,isconvecting,convection_triggered_time,q0,Δx,Δy,numelements_to_traverse_x,numelements_to_traverse_y, boundary_layer)
    Centered on each point it will traverese a square of numelements_to_traverse_y * numelements_to_traverse_y. If one of those neighbors is a convective center, it will heat the current point with the rules shown in:

Yang, D., and A. P. Ingersoll, 2013: Triggered Convection, Gravity Waves, and the MJO: A Shallow-Water Model. J. Atmos. Sci., 70, 2476–2486, https://doi.org/10.1175/JAS-D-12-0255.1.

If boundary_layer is true, heating substracts mass (reduces h). Else, convective heating adds mass (increases h).
"""
@inline function heat_at_point(i,j,k,current_time,τc,convective_radius,isconvecting,convection_triggered_time,q0,Δx2,Δy2,numelements_to_traverse, heating_stencil, boundary_layer = false)
    add_or_substract_mass = boundary_layer ? (-) : (+)
    forcing = 0.0
    @inbounds for neigh_j in (-numelements_to_traverse:numelements_to_traverse)
        @inbounds for neigh_i in (-numelements_to_traverse:numelements_to_traverse)
             if isconvecting[i + neigh_i , j + neigh_j]
                 forcing = add_or_substract_mass( forcing , heat(current_time,convection_triggered_time[i + neigh_i,j + neigh_j],τc,heating_stencil[-neigh_i,-neigh_j]))
             end
        end
    end 
    return forcing
end

"""
    u_damping(x, y, z, t, u, relaxation_parameter) = - u * relaxation_parameter
Create a linear damping function for the u field
"""
u_damping(x, y, z, t, u, relaxation_parameter) = - u * relaxation_parameter

"""
    v_damping(x, y, z, t, v, relaxation_parameter) = - v * relaxation_parameter
Create a linear damping function for the v field
"""
v_damping(x, y, z, t, v, relaxation_parameter) = - v * relaxation_parameter

"""
    fill_heating_stencil!(q,q0,Δx,R2)
Fills a stencil with the spatial profile of the heating.
Based on:

Yang, D., and A. P. Ingersoll, 2013: Triggered Convection, Gravity Waves, and the MJO: A Shallow-Water Model. J. Atmos. Sci., 70, 2476–2486, https://doi.org/10.1175/JAS-D-12-0255.1.
"""
function fill_heating_stencil!(::GPU,q,q0,Δx,R2)
    @cuda fill_heating_stencil_gpu!(q,q0,Δx,R2)
    return nothing
end

function fill_heating_stencil!(::CPU,q,q0,Δx,R2)
    fill_heating_stencil_cpu!(q,q0,Δx,R2)
    return nothing
end


function fill_heating_stencil_cpu!(q,q0,Δx,R2)
    for i in eachindex(q)
        if (i[1]^2 + i[2]^2)*Δx^2 <= R2 
            q[i] = q0 * (1.0 - ((i[1]^2 + i[2]^2)*Δx^2 / (R2))) /(pi*R2)
        else
            q[i] = 0.0
        end
    end
    return nothing
end


function fill_heating_stencil_gpu!(q,q0,Δx,R2)
    index_x = (blockIdx().x - 1) * blockDim().x + threadIdx().x
    stride_x = gridDim().x * blockDim().x

    index_y = (blockIdx().y - 1) * blockDim().y + threadIdx().y
    stride_y = gridDim().y * blockDim().y

    Nx = size(q,1)
    Ny = size(q,2)
    @inbounds for i in index_x:stride_x:Nx
        for j in index_y:stride_y:Ny            
            if (i^2 + j^2)*Δx^2 <= R2 
                q[i,j] = q0 * (1.0 - ((i^2 + j^2)*Δx^2 / (R2))) /(pi*R2)
            else
                q[i,j] = 0.0
            end
        end
    end
    return nothing
end

"""
    model_forcing(i,j,k,grid,clock,model_fields,parameters)
This is an interface with the correct signature to register the convective parameterization to Oceananigans.jl
It also adds the radiative cooling and the relaxation in the height field with a given timescale.
"""
function model_forcing(i,j,k,grid,clock,model_fields,parameters)
    boundary_layer = parameters.boundary_layer
    radiative_cooling_rate = boundary_layer ? parameters.radiative_cooling_rate : -1*parameters.radiative_cooling_rate
    heat_at_point(i,j,k,clock.time,
                      parameters.τ_c,
                      parameters.R,
                      parameters.isconvecting,
                      parameters.convection_triggered_time,
                      parameters.q0,
                      parameters.Δx2,
                      parameters.Δy2,
                      parameters.nghosts,
                      parameters.heating_stencil,parameters.boundary_layer) + radiative_cooling_rate - (model_fields.h[i,j,k] - parameters.relaxation_height)*parameters.relaxation_parameter
end

