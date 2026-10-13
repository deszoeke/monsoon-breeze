# NaN investigation log

Newest last. Each entry: symptom → test → conclusion.

1. **Eddy diffusivity runaway at the top (first GPU run, Float32).** Kᵘ jumped to 3×10⁴ m²/s and
   the run hit NaN at iteration 257. Capped K at 100 m²/s (`maximum_diffusivity`). That turned out
   to be a symptom of item 2. The cap stays as a safeguard.
2. **Domain-scale growth in the top cell (Float32), NaN after ~15 min.** It is the same on CPU
   and GPU and at 500 m and 4 km spacing, and absent on the small domain. A stronger sponge only
   delays it. **Cause: the Float32 anelastic pressure solve** (ill-conditioned for 512 km waves,
   ~(kΔz)⁻² ≈ 3×10⁴). Confirmed both ways: a Float32 model with a Float64 solve is stable, and a
   Float64 model with a Float32 solve fails. Fix: mixed precision (GPU default), ~2× faster than
   all-Float64. Also stretched Δz above 18 km (58 levels).
3. **NaN at the onset of convection, ~17.5 h (mixed precision, unbounded advection), in ≥ 2
   runs.** Max w went 0.1 → 27 m/s over ~2 h, then NaN.
   - Hypothesis: negative hydrometeors from unbounded WENO. Added bounded WENO (default). In a
     forced-condensation test, unbounded advection gave cloud and rain minima of ~−1e−14, bounded
     exactly 0.
   - Restart `adv_bounded` from 7699: **still NaN at 7934.** The only out-of-bounds warning was
     `ρe` (TKE ≥ −0.014, inherited from the checkpoint, cleared within 40 iterations). So
     negatives are not the cause.
   - Last diagnostics before the NaN: max ice number 3e3 → 5.5e4 /kg and max qi 1.3 → 5.4 g/kg in
     40 iterations; max w 28 m/s; 15k faces with K at the cap (at 655 m). NaN only in ρnⁱ
     (984 points, k = 1–40, starting at 25 m) and in wⁱ/wⁿⁱ (computed from nⁱ).
   - Hypothesis now: **fall Courant number > 1.** The Δt limit ignores fall speeds; rimed ice
     falls 10–20 m/s and the lowest cell is 50 m, at Δt = 8 s. CPU test: rain alone reaches a fall
     Courant number of 1.3–2.1 at Δt ≈ 8 s. `--sedimentation_cfl` keeps it at 0.7 (Δt ≈ 3.5–4 s).
     **Untested on the full run.**

Other open suspects if `sed_cfl` still fails: P3 itself (new, undertested in Breeze); mixed
precision (`conv_64`, all-Float64, passed the failure point: checkpoint at iteration 8243, 2026-10-11); K at the cap over a large area in the boundary layer.

## θˡⁱ sedimentation energy leak (2026-10-12)

A colleague using one-moment microphysics found that Breeze's ρθ tendency has no sedimentation
term. T = Π θˡⁱ + ℒ q / cᵖᵐ, so falling condensate changes T by ℒ Δq / cᵖᵐ at fixed θˡⁱ. The column
loses ℒ × (surface precipitation) of energy, so the latent heating of all the condensate that rains
out is undone. Our P3 runs have it too. In a CPU check, a 2 g/kg rain layer gives a spurious
+0.19 K s⁻¹ in the cell below it.

Fix: `--theta_sedimentation_fix` (`helpers/theta_sedimentation_correction.jl`) adds
−(ℒˡ Sˡ + ℒⁱ Sⁱ)/(cᵖᵐ Π) to Gρθ at every RK stage, with first-order upwind fluxes (Breeze sediments
with WENO, so it cancels the leak only to that accuracy). Tested: runs on CPU, correct sign and
size for a rain layer. Not yet on a full run. Issue draft: `breeze_issue_theta_sedimentation.md`.
Unknown whether it contributes to the NaN; it changes the convection a lot either way.

## `p3_fixes`: both fixes, P3 still fails in ice number (2026-10-12)

Restart from 7699 with `--theta_sedimentation_fix --sedimentation_cfl --debug_nan`. It passed
7934 (the `adv_bounded` failure) but hit NaN at iteration 8326, t = 17.64 h, Δt ≈ 3.7 s.

- The sedimentation CFL held: the fall Courant number stayed at 0.7, at z = 0–50 m.
- Ice number grew fast just before the NaN: max nⁱ 8.3×10³ → 1.75×10⁴ → 2.4×10⁴ /kg over 20
  iterations, at 8–9 km. That's the same pattern as `adv_bounded` (3×10³ → 5.5×10⁴ /kg).
- The NaN report, read carefully. "Fewest points first" misleads here, because P3's
  `surface_temperature` is 2D.
  - `surface_temperature` had 25 points, i.e. 25 columns.
  - ρθ, the moisture fields and T had 1450 points each = 25 columns × 58 levels, so every level
    of those columns.
  - `wⁱ` and `wⁿⁱ` had 1091 points, k = 1–29.
  - `ρnⁱ` had 3727 points, about 64 columns: **more** than any other field.
- So the ice number most likely went bad first. It had already spread sideways to more columns,
  while the other fields went NaN through whole columns at once. Column-wise operations do
  that, e.g. the P3 column surface temperature or the vertically implicit TKE diffusion.
- Kᵘ at the cap: about 20,000 faces at 655 m, and rising.
- `ρe` bounds warnings right after the restart: negative TKE inherited from the checkpoint,
  gone within 80 iterations, as before.

Conclusion: the sedimentation CFL and the θ fix delay the P3 failure by ~400 iterations but don't
remove it.
(Float32 may still matter for P3: `conv_64`, all-Float64 with plain P3, passed 8243. But the
colleague running one-moment in Breeze needed no Float64, not even for the pressure solve, on
different vertical levels. Our Float32 pressure-solve instability came from the tall, strongly
stratified column on the 512 km domain, so it may depend on the levels and domain.) Ice number blowing up in P3 remains the proximate cause. Switching to one-moment
(`one_moment_microphysics.md`).


## One-moment: negative rain and snow at the melting level (2026-10-12 – 13)

No NaN, but condensate goes negative at 4–5 km.
- **Rain:** the cause was snow and cloud ice collecting rain below 0 °C. The sink is explicit and
  uncapped, with τ ≈ 0.6–4 s against Δt ≈ 4–5 s. The CloudMicrophysics rate was checked by hand
  and is correct; it is fast because of the snow N₀.
  - Fix: `--implicit_rain_sink`.
  - First run with it (GH200, iterations 63500–64170): rain minimum −0.0073 g/kg, down from as
    low as −2 g/kg.
- **Snow:** with rain fixed, snow went negative just above 0 °C (worst −0.34 g/kg). The cause is
  the mirror image: rain collecting snow, plus warm-accretion melting, again explicit and uncapped.
  - The fix was extended to this sink. Not yet tested in a run.
- Details and numbers are in `STATUS.md`.
