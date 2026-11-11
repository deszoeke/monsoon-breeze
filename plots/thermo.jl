# Moist thermodynamics for the diagnostics in diag.jl, after cm1-out/Thermo.jl: saturation
# humidity (Buck 1981), the moist-adiabatic lapse rate parameter γ and the moist correction to N².
# Plain constants, no Breeze dependency (the plots environment has none). SI units, T in K, p in Pa.

module Thermo

export qs, γmoist, Nsq_moist_add, hydrostatic_pressure

const g = 9.81; const Rd = 287.04; const Rv = 461.5; const Cp = 1004.0
const Cpv = 1870.0; const Cw = 4190.0; const ε = Rd / Rv

Lv(T) = 2.501e6 + (Cpv - Cw) * (T - 273.15)

# saturation vapor pressure over liquid water (Pa), Buck 1981
es(T) = 611.21 * exp((18.678 - (T - 273.15) / 234.5) * (T - 273.15) / (257.14 + (T - 273.15)))

"Saturation specific humidity (kg/kg) at T (K), p (Pa)."
qs(T, p) = ε * es(T) / (p - (1 - ε) * es(T))

dqsdT(T, p; δ = 0.01) = (qs(T + δ, p) - qs(T - δ, p)) / 2δ

"γ = Lv/Cp ∂qs/∂T."
γmoist(T, p) = Lv(T) / Cp * dqsdT(T, p)

"The (negative) moist correction to N², N²ₘ = N² + Nsq_moist_add(T, p), as in cm1-out."
Nsq_moist_add(T, p) = (γ = γmoist(T, p); -g^2 / (Cp * T) * γ / (1 + γ))

"""
    hydrostatic_pressure(z, T, qv; p0 = 101_500.0)

Pressure (Pa) at heights z (m, increasing) from the hydrostatic equation with virtual temperature
T(1 + 0.608 qv), starting from `p0` at z[1]. The profile files hold no pressure.
"""
function hydrostatic_pressure(z, T, qv; p0 = 101_500.0)
    Tv = T .* (1 .+ 0.608 .* qv)
    p = similar(Tv); p[1] = p0
    for k in 2:length(z)
        p[k] = p[k-1] * exp(-g * (z[k] - z[k-1]) / (Rd * (Tv[k] + Tv[k-1]) / 2))
    end
    return p
end

end # module Thermo
