# EKAMSAT Arabian Sea sounding experiments (17 June 2023), the same soundings as the CM1
# cm1/soundings/input_sounding.<name> files (cm1/soundings/README.md describes them).
#
#     control = ekamsat_control()
#     exp1    = interp_1200_7200(control)
#     sounding = ekamsat_sounding(shear_set_4800m_u(restore_4800m_level(exp1); u = -8.0))
#
# exp0, the control, is the observed sounding idealized onto a few levels. exp1 interpolates it
# linearly from 1200 m to 7200 m, which weakens the wind shear and largely removes the control's dry
# layer. The other experiments restore the control's 4800 m level (θ and qv) on exp1, then change
# the wind at 4800 m or dry the 4800–7200 m layer. Each CM1 file is one of these combinations
# (cm1/soundings/check_soundings.jl checks that they match):
#
#     exp0  control                                     AS20230617
#     └─ exp1  interp_1200_7200                         AS12007200
#        └─ restore_4800m_level
#           ├─ shear_set_4800m_u(u = −8, −7.2, −0.4)    ASu4800-8, ASu4800-7p2, ASu4800-p4
#           └─ dry_layer(0.3 g/kg, 4800–7200 m)         ASdry4800-7200
#              └─ shear_set_4800m_u(u = −8)             ASdryu4800-8
#
# Needs `using MonsoonConvection` first (for Sounding). Only Vector{Float64}s reach the package, so
# choosing or changing a sounding never recompiles it.

#####
##### exp0: the control
#####

# Units as in CM1 input_sounding: pressure in hPa, θ in K, water-vapor mixing ratio qv in g/kg,
# wind in m/s. Each table row is one level.
ekamsat_surface() = (p = 1010.0, θ = 302.0, qv = 22.0)

ekamsat_control() = [
#      z (m)     θ (K)   qv (g/kg)  u (m/s)   v (m/s)
       40.0   302.0800   21.7667     8.1333    5.9333
     1000.0   304.0000   16.1667    11.3333    4.3333
     1200.0   305.3000   15.0000    12.0000    4.0000    # top of the low-level westerly jet
     2000.0   310.5000   10.3333     8.0000    2.0000
     2400.0   313.1000    8.0000     4.8000    0.8000
     2700.0   315.0500    3.0000     2.4000   -0.1000
     3000.0   317.0000    3.7500     0.0000   -1.0000
     3500.0   317.2778    5.0000    -2.2222   -1.2778
     4000.0   317.5556    4.5833    -4.4444   -1.5556
     4700.0   317.9444    4.0000    -7.5556   -1.9444
     4800.0   318.0000    2.7667    -8.0000   -2.0000    # top of the moist layer; mid-level easterly
     5000.0   320.4000    0.3000     0.0000    0.0000    # dry layer ...
     5200.0   322.8000    0.3000     1.2500    0.7500
     5800.0   330.0000    0.3000     5.0000    3.0000
     6500.0   333.1818    0.3000     4.5000    1.5000    # ... to here
     6800.0   334.5455    0.5400     4.2857    0.8571
     7000.0   335.4545    0.7000     4.1429    0.4286
     7200.0   336.3636    0.6200     4.0000    0.0000
     8000.0   340.0000    0.3000    -1.0000   -1.0000
     9000.0   342.0000    0.3000    -4.6000   -4.6000
    10500.0   345.0000    0.3000   -10.0000  -10.0000
    12000.0   350.5714    0.1380   -18.5714    0.0000
    13000.0   354.2857    0.0300   -24.2857    0.0000
    14000.0   358.0000    0.0210   -30.0000    0.0000
    16000.0   370.0000    0.0030   -45.0000   -2.4000    # tropical easterly jet
    16500.0   376.6667    0.0030   -40.0000   -3.0000
    17500.0   390.0000    0.0030   -30.0000    0.0000
    18000.0   405.0000    0.0030   -25.0000   -0.7500
    19500.0   450.0000    0.0100   -10.0000   -3.0000
    25000.0   630.0000    0.0100   -10.0000    0.0000
    40000.0  1010.8810    0.0000     0.0000    0.0000
]

#####
##### Changes
#####

# Each change takes a sounding table (rows of z, θ, qv, u, v) and returns a changed copy.

"""
exp1: drop the levels between 1200 m and 7200 m, so every profile is a straight line across that
layer, and set v = 0 at all heights.
"""
function interp_1200_7200(sounding)
    z = heights(sounding)
    sounding = sounding[(z .<= 1200) .| (z .>= 7200), :]
    sounding[:, col.v] .= 0
    return sounding
end

"""
Put back a 4800 m level with the control's θ and qv there (318 K, 2.77 g/kg, the top of the moist
layer). u and v stay on the straight line of the sounding it is added to.
"""
function restore_4800m_level(sounding; control = ekamsat_control())
    sounding = insert_level(sounding, 4800.0)
    observed = control[level_row(control, 4800.0), :]
    return set_level(sounding, 4800.0; θ = observed[col.θ], qv = observed[col.qv])
end

"""Set the wind at 4800 m to `u` (m/s). The control's mid-level easterly is u = −8 m/s."""
shear_set_4800m_u(sounding; u) = set_level(sounding, 4800.0; u)

"""
Set qv to `q` (g/kg) at the heights `levels` (m): a list of heights, or a tuple `(lev1, lev2)` for
every level from `lev1` to `lev2`.
"""
function dry_layer(sounding, q, levels)
    for z in heights_in(sounding, levels)
        sounding = set_level(sounding, z; qv = q)
    end
    return sounding
end

heights_in(sounding, (lev1, lev2)::Tuple) = filter(z -> lev1 <= z <= lev2, heights(sounding))
heights_in(sounding, levels) = levels

# Tools for the changes above

const col = (z = 1, θ = 2, qv = 3, u = 4, v = 5)

heights(sounding) = sounding[:, col.z]

function level_row(sounding, z)
    rows = findall(==(z), heights(sounding))
    length(rows) == 1 || throw(ArgumentError("expected one sounding level at z = $z m"))
    return only(rows)
end

"""Insert a level at height `z`, on the straight line between the levels below and above it."""
function insert_level(sounding, z)
    above = findfirst(>(z), heights(sounding))
    below = above - 1
    weight = (z - sounding[below, col.z]) / (sounding[above, col.z] - sounding[below, col.z])
    new = sounding[below:below, :] .+ weight .* (sounding[above:above, :] .- sounding[below:below, :])
    return [sounding[1:below, :]; new; sounding[above:end, :]]
end

"""Set the values named in `values` (θ, qv, u or v) at the existing level at height `z`."""
function set_level(sounding, z; values...)
    sounding = copy(sounding)
    row = level_row(sounding, z)
    for (name, value) in values
        sounding[row, col[name]] = value
    end
    return sounding
end

#####
##### Sounding
#####

"""
    ekamsat_sounding(table)

The sounding `table` (rows of z, θ, qv, u, v) as a `Sounding`, built as `read_cm1_sounding` builds
one from a CM1 file: the surface values become a level at z = 0 with the wind of the lowest level,
and the units become Pa and kg/kg.
"""
function ekamsat_sounding(table)
    surface = ekamsat_surface()
    z = [0.0;        table[:, col.z]]
    θ = [surface.θ;  table[:, col.θ]]
    r = [surface.qv; table[:, col.qv]] ./ 1000
    u = [table[1, col.u]; table[:, col.u]]
    v = [table[1, col.v]; table[:, col.v]]
    return Sounding(100 * surface.p, z, θ, r, u, v)
end
