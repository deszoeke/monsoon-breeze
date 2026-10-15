# EKAMSAT Arabian Sea sounding experiments

CM1 `input_sounding` files (`isnd = 7`) for the EKAMSAT Arabian Sea monsoon-convection case. All of
them come from one observed sounding, `AS20230617`. The others simplify its 1.2–7.2 km layer to
test what the mid-level dry layer and the low-level wind shear each do. The model setup is the same
for all of them: 1024 × 512 at 500 m, 10°N, fixed 301 K SST, perpetual sun (see `../README` and
`../namelist.input`).

CM1 always reads a file named `input_sounding`. To run an experiment, `input_sounding` was linked or
copied from one of these files; it is a temporary input, not an experiment of its own.

The Breeze driver doesn't read these files. The same soundings are Julia tables in
`helpers/ekamsat_soundings.jl`: the control is a table, and functions build each experiment from it.
`monsoon_convection.jl` builds `ASdryu4800-8` this way. `check_soundings.jl` checks that every
experiment matches its CM1 file exactly.

## File format

- **First line:** surface pressure (hPa), surface θ (K), surface water-vapor mixing ratio qv (g/kg).
- **Each further line:** height z (m), θ (K), qv (g/kg), u (m/s), v (m/s).

CM1 interpolates linearly in z between the levels.

## What all the files share

- **Surface:** 1010 hPa, θ = 302 K, qv = 22 g/kg.
- **Boundary layer and low-level jet:** the 40, 1000 and 1200 m levels. u rises to a 12 m/s
  westerly at 1200 m, and qv falls to 15 g/kg.
- **Above 7.2 km:** the upper troposphere and stratosphere. Easterlies strengthen to a −45 m/s
  tropical easterly jet at 16 km. The tropopause θ jump is at about 16–18 km. The top level is
  40 km.

## The observed sounding: `AS20230617`

The sounding is from 17 June 2023. It has 32 levels with the full structure:
- **Moist layer:** qv falls from 15 g/kg at 1200 m to 2.8 g/kg at 4800 m.
- **Dry layer:** qv = 0.3 g/kg from 5000 to 6500 m, with θ rising sharply (318 → 333 K).
- **Wind:** u turns from the 12 m/s westerly jet at 1200 m to an −8 m/s easterly at 4800 m. That
  is 20 m/s of shear across 3.6 km. Above it, u turns back to a +5 m/s westerly at 5.8 km.
- **v:** nonzero, a few m/s.

## Simplified soundings

Each simplified file keeps the shared levels and replaces everything between 1200 and 7200 m with
at most one level, at 4800 m. All have v = 0.

If there were no 4800 m level, linear interpolation from 1200 m to 7200 m would give these values at
4800 m: θ ≈ 323.9 K, qv ≈ 6.4 g/kg, u = +7.2 m/s. The files with a 4800 m level use θ = 318 K
there, the observed value, so their 1.2–4.8 km layer is cooler than the interpolation.

In the names, `dry` means qv = 0.3 g/kg from 4800 m to 7200 m. The number after `u4800` is u at
4800 m, with `-` meaning minus and `p` meaning a decimal point.

| File | Level at 4800 m: θ, qv, u | qv at 7200 m | What it tests |
|---|---|---|---|
| `AS12007200` | none (interpolated: ≈323.9 K, ≈6.4 g/kg, +7.2 m/s) | 0.62 | Smooth control: no dry layer, no wind reversal |
| `ASu4800-8` | 318 K, 2.77 g/kg, −8 m/s | 0.62 | Observed shear, no dry layer |
| `ASu4800-7p2` | 318 K, 2.77 g/kg, −7.2 m/s | 0.62 | As `ASu4800-8`, slightly weaker easterly |
| `ASu4800-p4` | 318 K, 2.77 g/kg, −0.4 m/s | 0.62 | Weak shear, no dry layer |
| `ASdry4800-7200` | 318 K, 0.3 g/kg, +7.2 m/s | 0.3 | Dry layer, no wind reversal (u is the interpolated value) |
| `ASdryu4800-8` | 318 K, 0.3 g/kg, −8 m/s | 0.3 | Dry layer and observed shear |

Together these separate the two features of the observed sounding:
- **Shear without the dry layer:** `ASu4800-*`, with the 4800 m easterly at −8, −7.2 and −0.4 m/s.
- **Dry layer without shear:** `ASdry4800-7200`.
- **Both:** `ASdryu4800-8`.
- **Neither:** `AS12007200`.

## The current `cm1/input_sounding`

The `cm1/input_sounding` in the repository is a copy of `ASdryu4800-8`, the dry layer with the
−8 m/s shear. It was the input of the CM1 run whose `cm1.print.out` is kept in `cm1/`.
