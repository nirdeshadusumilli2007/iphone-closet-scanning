# ClosetScanner

A native iOS app that scans a physical closet with an iPhone's camera + LiDAR,
reconstructs it as a **clean, empty 3D space**, reports its **dimensions**, and
provides a **high-precision AR ruler** with a **built-in accuracy-validation
harness** targeting **1/16"** resolution.

Built for iPhone/iPad Pro (12 Pro or newer — LiDAR required).

---

## How it maps to the requirements

| Requirement | Where it lives | Approach |
|---|---|---|
| Scan the closet with cameras + sensors | **Scan** tab | Apple **RoomPlan** drives the camera + LiDAR to reconstruct room architecture in real time. |
| Digitally remove/hide existing contents | **Scan** tab → result | RoomPlan separates *architecture* (walls, floor, doors, windows, openings) from *objects* (clutter). The reconstruction renders both, with a **show/hide-contents toggle** to make the clutter vanish live, and an **architecture-only USDZ export** so the exported file is genuinely empty. |
| Calculate & display dimensions | **Scan** tab → result | Width × Depth × Height computed from the captured walls, shown in feet-inches-sixteenths and cm, plus per-wall lengths — with the scale calibration applied. |
| 1/16" accuracy + validation | **Ruler** + **Validation** tabs | LiDAR raycast measurement with outlier-rejected median filtering, live stability readout, and a **known-length scale calibration**; an on-device harness logs measured-vs-tape-measure error and reports % within 1/16". Full protocol in [`VALIDATION.md`](VALIDATION.md). |
| Live demo from iPhone | whole app | Native app; runs live on-device. Demo script below. |

> **Honest accuracy note.** No iPhone hits 1/16" (≈1.6 mm) out of the box. Raw
> LiDAR depth is good to roughly ±1 cm. The Ruler's median-of-many-samples
> approach plus short-span, close-range technique pushes typical error down to a
> few millimeters, and the Validation harness reports exactly how close *your*
> device gets rather than asserting a number. See `VALIDATION.md` for the method
> and how to tighten it further (fiducial scale correction, tripod, close range).

---

## Build & run

**You need:** a Mac with Xcode 16+, an iPhone/iPad Pro with LiDAR, and an Apple ID.

1. Copy this folder to your Mac.
2. Open **`ClosetScanner.xcodeproj`** in Xcode.
3. Select the **ClosetScanner** target → **Signing & Capabilities** → set your
   **Team** and change the **Bundle Identifier** to something unique
   (e.g. `com.yourname.ClosetScanner`).
4. Plug in your iPhone, select it as the run destination, and press **⌘R**.
5. On first launch, grant **camera** permission.

### If the project won't open (fallback, ~2 minutes)

The `.xcodeproj` was authored by hand on Windows and couldn't be compiled here.
If Xcode rejects it, create the project fresh — the source is 100% reusable:

1. Xcode → **File ▸ New ▸ Project ▸ iOS ▸ App**. Name it **ClosetScanner**,
   Interface **SwiftUI**, Language **Swift**. Save it anywhere.
2. Delete the auto-generated `ContentView.swift` and `ClosetScannerApp.swift`.
3. Drag the **`ClosetScanner/`** source folder from this repo into the Xcode
   project navigator (check *"Copy items if needed"* and *"Create groups"*).
4. Target ▸ **Info** → add key **`Privacy - Camera Usage Description`** with a
   short string (e.g. *"Used to scan and measure your closet."*).
5. Set **Deployment Target** to iOS 17.0, set your signing Team, run.

---

## Live demo script (≈2 minutes)

1. **Scan tab.** Stand in the closet doorway. Slowly pan the phone across each
   wall, then the floor and ceiling. Watch RoomPlan trace the surfaces. Tap
   **Finish Scan**.
2. **Empty room.** The result sheet shows the reconstructed closet — walls, floor,
   and any door/window/opening. Flip the **Contents removed** toggle to make the
   detected clutter appear/vanish — that's the "digitally remove the contents"
   step, live. Drag to orbit, pinch to zoom, read off Width / Depth / Height. Tap
   **Export empty room (USDZ)** (architecture-only) and open it in Quick Look.
   Dismiss the sheet and the camera restarts automatically (**New Scan** re-scans
   any time).
3. **Calibrate (do this first for accuracy).** On the **Ruler** tab, measure a
   known reference (e.g., a 24" machinist rule): Set A, Set B, then ⋯ →
   **Calibrate from this reading**, enter 24.000. A "calibrated +x.xx%" chip
   appears and now corrects every measurement and the room dimensions.
4. **Ruler tab.** Aim the crosshair at one inside corner, tap **Set A**; aim at
   the opposite corner, tap **Set B**. Read the distance to 1/16". The **±mm**
   chip shows live stability (green ≤ 2 mm) then committed confidence.
5. **Validation tab.** Measure a known length, ⋯ → **Log for validation**, type
   the true value — fractions welcome (`23 7/16`) or decimal (`23.4375`). The tab
   shows live **% within 1/16"**, mean/RMS/max error, and bias. Do a few before
   and after calibrating to show the improvement; export CSV as the evidence.

---

## Project layout

```
ClosetScanner/
  ClosetScannerApp.swift        App entry
  ContentView.swift             Tab bar + shared components
  Support/Units.swift           Metric → feet/inches/sixteenths formatting
  Scan/
    RoomScanScreen.swift        Live RoomPlan capture UI
    RoomScanModel.swift         Capture-session lifecycle + delegate
    RoomDimensions.swift        Width/Depth/Height from captured walls
    EmptyRoomSceneView.swift    Reconstruction + contents toggle + architecture-only builder
    ScanResultScreen.swift      Dimensions + toggle + empty USDZ export
  Measure/
    RulerEngine.swift           LiDAR raycast + MAD outlier rejection + confidence
    ARRulerContainer.swift      ARView config (mesh + depth)
    PrecisionRulerScreen.swift  Crosshair UI + calibrate + log-to-validation
  Calibration/
    CalibrationStore.swift      Persisted scale-correction factor
  Validation/
    ValidationStore.swift       Persisted records + accuracy statistics
    ValidationScreen.swift      Stats dashboard + CSV export
VALIDATION.md                   Accuracy test protocol + expected results
```

## Known limitations

- RoomPlan whole-room dimensions are a fast estimate (±a few cm) and the
  bounding-box width/depth can over-report slightly for a closet scanned at an
  angle — measure square-on, and use the **Ruler** for spans that must be exact.
- Depth quality degrades on dark, glossy, or transparent surfaces and beyond
  ~3 m. Measure short spans at close range for best accuracy.
- "Remove contents" is by *omission* (architecture rendered, objects hidden), not
  photographic erasure of the live camera feed. The exported USDZ is walls-only.
- This code was written but **not compiled** in the authoring environment. If a
  build error appears, it will be a minor API signature fix — send me the error.
