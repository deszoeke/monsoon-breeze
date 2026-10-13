# Temperature and rain-loss timescales at one cell, and a hand check of CloudMicrophysics'
# snow-collects-rain rate against its own formula and against Lin, Farley & Orville (1983).
# Run from the repository directory (CPU, no checkpoint needed; cell values are typed in below,
# from helpers/negative_condensate.jl on checkpoint 63496):
#
#   julia --project helpers/rain_snow_accretion_check.jl
#
using MonsoonConvection
using MonsoonConvection: θ̄, q̄ᵗ, cm1_z_faces, read_cm1_sounding
using Breeze, Oceananigans
using Breeze.Thermodynamics: LiquidIcePotentialTemperatureState, MoistureMassFractions, temperature
using Printf

const H = 5
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

z_faces = stretched_top_faces(Δz_top = 1000)
Nz = length(z_faces) - 1
s = read_cm1_sounding(joinpath(pkgdir(MonsoonConvection), "..", "cm1", "input_sounding"))
column = RectilinearGrid(CPU(); size = Nz, z = z_faces, halo = H, topology = (Flat, Flat, Bounded))
constants = ThermodynamicConstants()
rs = ReferenceState(column, constants; base_pressure = s.p₀,
                    potential_temperature = z -> θ̄(s, z), vapor_mass_fraction = z -> q̄ᵗ(s, z))

k = 19
ρ  = interior(rs.density)[1, 1, k]
pᵣ = interior(rs.pressure)[1, 1, k]
pˢᵗ = rs.standard_pressure
θli = 311.62180786854356
qᵛ, qᶜˡ, qᶜⁱ, qʳ, qˢⁿ = 6.768e-3, 1.43e-3, 0.07962e-3, -0.3552e-3, 1.57e-3

@printf "z = %.0f m, ρᵣ = %.4f kg/m³, pᵣ = %.1f hPa, pˢᵗ = %.1f hPa\n" (z_faces[k]+z_faces[k+1])/2 ρ pᵣ/100 pˢᵗ/100
for (label, qr) in (("as stored (qʳ < 0)", qʳ), ("qʳ clipped to 0", 0.0))
    q = MoistureMassFractions(qᵛ, qᶜˡ + qr, qᶜⁱ + qˢⁿ)
    T = temperature(LiquidIcePotentialTemperatureState(θli, q, pˢᵗ, pᵣ), constants)
    @printf "T (%s) = %.3f K = %+.3f °C\n" label T T - 273.15
end

# Rain-loss rates from Breeze's own wrappers, default parameters
ext = Base.get_extension(Breeze, :BreezeCloudMicrophysicsExt)
cats = ext.one_moment_cloud_microphysics_categories(Float64)
P = cats.parameters
pp = P.process_params
rain, snow = P.precip.rain, P.precip.snow
vr, vs = P.terminal_velocity.rain, P.terminal_velocity.snow
cloud_ice = P.cloud.ice

println("\nRain loss at qˢⁿ = 1.57 g/kg, qᶜⁱ = 0.08 g/kg (cold branch, T < 273.15 K)")
println("  qʳ g/kg   Sʳˢⁿ (1/s)   τ_rsn (s)   Sᵃᶜᶜʳⁱ (1/s)   τ_ri (s)   τ_total (s)")
for qr in (2e-3, 1e-3, 0.5e-3, 0.2e-3, 0.1e-3, 0.03e-3, 0.01e-3, 1e-6)
    Srsn = ext.rain_snow_accretion(pp.rain_snow_accretion, snow, rain, vs, vr, qˢⁿ, qr, ρ)
    Sri  = ext.rain_sink_accretion(pp.cloud_ice_rain_accretion, rain, cloud_ice, vr, qᶜⁱ, qr, ρ)
    @printf "  %7.4f  %11.3e  %10.2f  %13.3e  %9.2f  %10.2f\n" qr*1e3 Srsn qr/Srsn Sri qr/Sri qr/(Srsn+Sri)
end

# --- Hand check of the snow-collects-rain rate -------------------------------------------
# (a) Re-derive CloudMicrophysics' formula from its parameters, independently of its code:
#     S = (1/ρ) ∫∫ π (rₛ + r_r)² ΔV m_r(r_r) n_s(rₛ) n_r(r_r) drₛ dr_r,
#     n(r) = n₀ exp(-r/λ⁻¹), m(r) = m₀ χm (r/r₀)^δ, δ = me + Δm.
# (b) Lin, Farley & Orville (1983) PSACR with their own parameters, for comparison.
# Γ(x) by the Lanczos approximation (g = 7), ~1e-15 relative; avoids a SpecialFunctions dependency
function gamma(x::Real)
    x < 0.5 && return π / (sin(π * x) * gamma(1 - x))
    c = (0.99999999999980993, 676.5203681218851, -1259.1392167224028, 771.32342877765313,
         -176.61502916214059, 12.507343278686905, -0.13857109526572012,
         9.9843695780195716e-6, 1.5056327351493116e-7)
    x -= 1
    a = c[1] + sum(c[i+1] / (x + i) for i in 1:8)
    t = x + 7.5
    return sqrt(2π) * t^(x + 0.5) * exp(-t) * a
end
println("\nParameters (CloudMicrophysics defaults, radius-based Marshall–Palmer):")
function mp(pdf_n0, mass, q)
    (; r0, m0, me, Δm, χm) = mass
    δ = me + Δm
    λinv = (ρ * q * r0^δ / (χm * m0 * pdf_n0 * gamma(δ + 1)))^(1 / (δ + 1))
    return λinv, δ
end
vfall(vel, mass, v0, λinv) = vel.χv * v0 * (λinv / mass.r0)^(vel.ve + vel.Δv) *
                             gamma(mass.me + vel.ve + mass.Δm + vel.Δv + 1) / gamma(mass.me + mass.Δm + 1)
n0s = snow.pdf.μ * (ρ * qˢⁿ)^snow.pdf.ν
n0r = rain.pdf.n0
λs, δs = mp(n0s, snow.mass, qˢⁿ)
v0r = sqrt(8 * (vr.ρw / ρ - 1) * vr.grav * vr.r0 / (3 * vr.C_drag))
Vs = vfall(vs, snow.mass, vs.v0, λs)
@printf "  snow: n₀ = %.3e m⁻⁴ (per radius; %.3e per diameter), λ⁻¹ = %.3f mm, mass-weighted V = %.2f m/s\n" n0s n0s/2 λs*1e3 Vs
@printf "        m₀ = %.3e kg, r₀ = %.0e m, δ = %.2f  (mass at r = 1 mm: %.2e kg)\n" snow.mass.m0 snow.mass.r0 δs snow.mass.m0
@printf "  rain: n₀ = %.3e m⁻⁴ (per radius; %.3e per diameter), E(rain–snow) = %.2f, dispersion = %.2f\n" n0r n0r/2 pp.rain_snow_accretion.e pp.rain_snow_accretion.coeff_disp

println("\n  qʳ g/kg   λ⁻¹ʳ mm  Vʳ m/s   S_CM (code)   S_hand (a)   S_Lin (b)    τ_CM s   τ_Lin s")
for qr in (2e-3, 1e-3, 0.5e-3, 0.2e-3, 0.1e-3, 0.01e-3)
    S_code = ext.rain_snow_accretion(pp.rain_snow_accretion, snow, rain, vs, vr, qˢⁿ, qr, ρ)
    # (a)
    λr, δr = mp(n0r, rain.mass, qr)
    Vr = vfall(vr, rain.mass, v0r, λr)
    c = pp.rain_snow_accretion.coeff_disp
    ΔV = sqrt((Vs - Vr)^2 + c * (Vs^2 + Vr^2))
    (; r0, m0, χm) = rain.mass
    I = 2λs^3 * gamma(δr + 1) * λr^(δr + 1) + 2λs^2 * gamma(δr + 2) * λr^(δr + 2) + λs * gamma(δr + 3) * λr^(δr + 3)
    S_hand = π / ρ * n0s * n0r * m0 * χm / r0^δr * pp.rain_snow_accretion.e * ΔV * I
    # (b) Lin et al. (1983) eq. 28 / Rutledge & Hobbs (1983); diameter-based, SI units
    ρw, ρsn, n0R, n0S, ρ₀ = 1000.0, 100.0, 8e6, 3e6, 1.2
    ΛR = (π * ρw * n0R / (ρ * qr))^0.25
    ΛS = (π * ρsn * n0S / (ρ * qˢⁿ))^0.25
    VR = 842.0 * gamma(4.8) / (6 * ΛR^0.8) * sqrt(ρ₀ / ρ)
    VS = 4.836 * gamma(4.25) / (6 * ΛS^0.25) * sqrt(ρ₀ / ρ)
    S_Lin = π^2 * 1.0 * abs(VR - VS) * n0R * n0S * (ρw / ρ) *
            (5 / (ΛR^6 * ΛS) + 2 / (ΛR^5 * ΛS^2) + 0.5 / (ΛR^4 * ΛS^3))
    @printf "  %7.3f  %7.3f  %6.2f   %11.3e  %11.3e  %11.3e  %8.2f  %8.1f\n" qr*1e3 λr*1e3 Vr S_code S_hand S_Lin qr/S_code qr/S_Lin
end
