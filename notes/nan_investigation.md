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
precision (compare with `conv_64`); K at the cap over a large area in the boundary layer.
