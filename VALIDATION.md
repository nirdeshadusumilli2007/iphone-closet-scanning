# Accuracy Validation Protocol

Target: **±1/16 inch (±1.5875 mm)** on measured lengths.

This document defines how the app's measurement accuracy is tested, what results
to expect, why, and how to push accuracy toward the target. The app ships with a
**Validation** tab that automates the data capture and statistics described here.

---

## 1. What "1/16 inch" really costs on an iPhone

The iPhone Pro LiDAR is a **time-of-flight** sensor with a low-resolution depth
map (~256×192) upsampled with the RGB image. Realistic per-point depth noise is
**±5–10 mm** at close range, growing with distance and degrading on dark, glossy,
or transparent surfaces. Apple's RoomPlan reports room dimensions to within a
few centimeters.

So 1/16" (1.6 mm) is **below the raw single-shot noise floor**. Getting there
requires attacking every error source deliberately:

| Error source | Mitigation in this app | Further mitigation |
|---|---|---|
| Random depth noise per frame | **Median of ~30 raycasts** at a fixed pixel; median rejects outliers better than mean | Longer averaging window; tripod |
| Aiming jitter | **Fixed screen-center crosshair** (one stable pixel, not a finger tap) | Tripod / phone mount |
| Distance-dependent noise | Encourage **close range** (< 0.5 m) and **short spans** | Measure edge-to-edge in segments and sum |
| Tracking drift over the span | Measure A and B within a few seconds without walking | Keep both points in view; re-localize |
| Scale error (VIO/LiDAR) | Report **systematic bias** so scale error is visible | **Fiducial marker** of known size for scale correction (below) |
| Poor surface for ToF | Confidence readout warns when spread is high | Add matte tape/target to glossy corners |

The honest headline: **we don't claim a fixed number — we measure and report the
error distribution for the actual device**, and the technique below routinely
brings *close-range, short-span* readings into the low-millimeter range.

---

## 2. Reference targets (ground truth)

Use rigid, factory-toleranced references — not a soft tape stretched by hand:

1. **Machinist steel rule, 24"** (±0.01" tolerance) — primary short reference.
2. **Precision-cut plywood/MDF panel** measured with calipers — mid reference.
3. **A door opening** measured with a quality steel tape, read twice — long
   reference (closet-scale).
4. Optional: **printed calibration sheet** with a known 200.0 mm line, laser-
   printed and verified with calipers (printers scale ~0.5%, so verify, don't
   assume).

Record each reference's true length to 0.001" (or 0.01 mm).

---

## 3. Test procedure

For **each** reference length:

1. Place the reference flat, well-lit, matte surface facing the phone.
2. In the **Ruler** tab, brace the phone ~30–40 cm away.
3. Aim crosshair at endpoint 1 → **Set A**. Wait until the **±mm** confidence
   chip settles below ~2 mm.
4. Aim at endpoint 2 → **Set B**.
5. Tap the **seal** button; enter the reference's true length in inches → **Save**.
6. **Repeat 8–10 times per reference**, re-aiming each time (don't reuse a pose).

Do this across **≥3 references** spanning short/mid/long. Target **≥30 total
samples**. Export the CSV from the Validation tab (⋯ menu).

### Acceptance criteria
- **Primary:** ≥ 90% of readings within **±1/16"**.
- **Secondary:** RMSE ≤ 1/16"; |systematic bias| ≤ 1/32" (otherwise apply scale
  correction, §5).

---

## 4. Metrics the app computes

For each record: `error = measured − ground_truth` (inches and mm), and a
pass/fail against ±1/16". Aggregate:

- **% within 1/16"** — the headline pass rate.
- **Mean absolute error** — typical miss.
- **RMSE** — penalizes large misses; the honest summary figure.
- **Max error** — worst case.
- **Systematic bias** (signed mean) — a non-zero value means a scale/offset error
  that §5 can correct; near-zero means the error is purely random noise.

Exported CSV columns:
`timestamp, ground_truth_in, measured_in, error_in, abs_error_in, error_mm, within_1_16`

---

## 5. Scale / bias correction (how to actually reach 1/16")

If the CSV shows a consistent **bias** (e.g., every reading is +0.8% long), it's a
scale error, not random noise, and it's correctable. **This is built into the app**:

1. On the **Ruler** tab, measure the **24" rule** (Set A / Set B).
2. Tap **⋯ → Calibrate from this reading** and enter `24.000`. The app computes
   `k = true / measured` and shows a "calibrated +x.xx%" chip.
3. `k` is now applied to every measurement *and* to the room dimensions. Re-run
   the validation — bias should collapse toward zero and the ±1/16" pass rate
   should jump. Capture the before/after as your headline result.

A physical **fiducial marker** (e.g., a printed ArUco tag of precisely known
edge length placed in-frame) is the rigorous version: detect it, compare its
apparent size to its true size, and derive `k` live. This is the standard way
metrology-grade AR apps beat the raw sensor.

---

## 6. Expected results (what "good" looks like)

With close-range (30–40 cm), short spans (< ~30"), matte surfaces, median
filtering, and bias correction applied:

- **Within 1/16":** ~85–95% of readings.
- **RMSE:** ~1–2 mm (≈ 0.04–0.08").
- **Bias after correction:** < 0.5 mm.

Without correction / at longer range / on poor surfaces, expect 5–10 mm errors
and a lower pass rate — which the harness will show honestly. That transparency
*is* the validation: the app doesn't hide error, it quantifies it.

---

## 7. Reproducing the report

1. Run the procedure in §3 to ≥30 samples.
2. Screenshot the **Validation** summary (live % within 1/16", RMSE, bias).
3. Export the CSV as the raw evidence.
4. If bias > 1/32", apply §5 correction and re-run to show the improvement.

Together these demonstrate *how* accuracy was tested and *what* accuracy was
achieved on the specific device used for the demo.
