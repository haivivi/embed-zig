# WebRTC AEC3 vs Our Implementation Analysis

## Architecture Comparison

### WebRTC AEC3 (from ewan-xu/AEC3)

**Core Components:**
1. **Dual Filters** (Main + Shadow)
   - Main: Conservative, `leakage_converged=0.00005f`, slow but stable
   - Shadow: Fast tracking, `rate=0.7f`, quick adaptation
   - Selector: Chooses best output based on echo return loss

2. **Frequency Domain Processing**
   - `SplitIntoFrequencyBands()` - 分频带处理
   - Per-band adaptive filtering and suppression
   - `MergeFrequencyBands()` - 合并输出

3. **Multi-level Near-end Detection**
   - `dominant_nearend_detection`: Power ratio + SNR check
     - `enr_threshold=0.25f`, `snr_threshold=30f`
     - `hold_duration=50` frames, `trigger_threshold=12`
   - `subband_nearend_detection`: Per-band detection
   - `nearend_average_blocks=4`: Time smoothing

4. **State Management**
   - Initial phase: `initial_state_seconds=2.5f`
   - Filter switching: Main ↔ Shadow based on convergence
   - Echo audibility tracking

5. **Dynamic Delay Control**
   - `default_delay=5` blocks (~50ms)
   - External delay estimator support
   - `delay_selection_thresholds={5, 20}`

6. **Two-stage Tuning**
   - `normal_tuning`: ERLE-based suppression
     - `mask_lf={0.3f, 0.4f, 0.3f}` (ENR thresholds)
   - `nearend_tuning`: Near-end protection
     - `mask_lf={1.09f, 1.1f, 0.3f}` (much higher thresholds)

### Our Implementation

**Current:**
1. Single adaptive filter (no Main/Shadow)
2. No frequency band splitting
3. Simple near-end check: `error/ref ratio` only
4. No state machine (just `smoothed_cancel_ratio`)
5. Fixed 1-frame delay
6. Single suppression tuning

**Config Comparison:**
| Parameter | WebRTC | Ours |
|-----------|--------|------|
| Filters | Main(13 blocks) + Shadow(13 blocks) | Single (10 partitions) |
| Main leakage | 0.00005f (converged), 0.05f (diverged) | 0.5 (step_size) |
| Shadow rate | 0.7f | N/A |
| Near-end hold | 50 frames | None |
| ENR threshold (normal) | 0.3f / 0.4f | ~0.003f |
| ENR threshold (near-end) | 1.09f / 1.1f | Same as normal |

## CL3 Test Failure Analysis

**Test:** `CL3: closed-loop with near-end speech`
- Phase 1 (200 frames): Pure echo, AEC converges
- Phase 2 (100 frames): Near-end (880Hz sine) + echo

**Result:** clean_rms=604 vs near_rms=5656 (~10% preserved, expected >=30%)

**Root Causes:**

1. **No Near-end Mode Switching**
   - WebRTC: When near-end detected, switches to `nearend_tuning`
   - Our: Uses same NLP parameters regardless
   - Result: Near-end speech gets suppressed

2. **No Fast Attack Detection**
   - WebRTC: `dominant_nearend_detection` with `trigger_threshold=12` frames
   - Our: Relies on slow `smoothed_cancel_ratio` (alpha=0.7)
   - Result: 10-20 frame delay before recognizing near-end

3. **Single Filter = No Tracking/Convergence Tradeoff**
   - WebRTC: Shadow filter tracks changes, Main provides stability
   - Our: Single filter can't do both well

4. **No Frequency Domain Processing**
   - WebRTC: Per-band suppression (different gains for different freqs)
   - Our: Full-band processing loses spectral information

## Required Fixes (Priority Order)

### P0: Near-end Detector + Mode Switching
Implement minimal nearend_detector:
```zig
pub fn detect(mic_energy, ref_energy, error_energy) -> NearEndState {
    // Fast power ratio check
    if (mic_energy > ref_energy * threshold) {
        near_end_counter++;
    } else {
        near_end_counter = max(0, near_end_counter - 1);
    }
    
    // Hysteresis: trigger_threshold=12, hold_duration=50
    return near_end_counter > 12;
}
```

When near-end detected:
- Skip NLP entirely: `clean = error_td` directly
- Or use very high floor: `nlp_floor = 0.9` (instead of 0.003)

### P1: Dual Filter Architecture
Add Shadow filter:
- Main: Keep current (slow, stable)
- Shadow: Faster step_size, tracks quick changes
- Selector: Choose based on echo return loss estimate

### P2: Frequency Domain Processing
Split into bands:
- Low freq (0-4kHz): Echo dominated, aggressive suppression
- High freq (4-8kHz): Near-end often dominant, gentle suppression

### P3: State Machine
States:
- `Initial` (2.5s): Conservative, no suppression
- `Converged`: Normal operation
- `NearEnd`: Skip suppression
- `DoubleTalk`: Shadow filter active

## MCU/ESP32 Constraints

**Current Fixed-Point Support:**
- `arithmetic.zig` provides `Arith.add`, `mul`, `div`, `sqrt` abstractions
- `GenAec3(comptime Arith)` generic for both f32 (desktop) and i32 Q15 (ESP32)
- **Constraint**: No bare `f32` math, all operations through `Arith` layer

**WebRTC on MCU Challenges:**
- WebRTC AEC3 uses heavy floating-point
- Port to MCU requires fixed-point conversion or libm soft-float
- Current approach: Zig comptime abstraction (cleaner than #ifdef)

## Simplified Fix for CL3 (MCU-Compatible)

**Constraint**: Use only `Arith` operations, no bare f32.

Replace near-end check in `aec3.zig`:
```zig
// Current (slow, causes CL3 failure):
const apply_nlp = self.smoothed_cancel_ratio > 0.01 
              and self.smoothed_cancel_ratio < 1.5;

// Fix (fast power ratio, MCU-compatible):
// Calculate mic_energy / ref_energy using Arith abstraction
const mic_energy_f = Arith.toFloat(mic_energy);  // Works for both f32 and i32
const ref_energy_f = Arith.toFloat(ref_energy);
const ratio = if (ref_energy_f > 0) 
    mic_energy_f / ref_energy_f 
else 
    999.0;  // Large ratio = near-end

const is_near_end = ratio > 2.0;  // mic > 2x ref

const apply_nlp = !is_near_end  // Skip NLP when near-end detected
              and self.smoothed_cancel_ratio > 0.01 
              and self.smoothed_cancel_ratio < 1.5;
```

**Alternative (more MCU-friendly)**: Use energy comparison directly in fixed-point:
```zig
// i32 comparison: mic_energy > ref_energy * 2
// In Q15: multiply by 2 = left shift by 1
const threshold = Arith.add(ref_energy, ref_energy);  // ref * 2
const is_near_end = mic_energy > threshold;
```

This avoids float conversion entirely for the fixed-point path.

## Implementation Strategy

**Phase 1 (Immediate)**: Fast near-end detection
- Add `near_end_counter` to Aec3 state
- Fast power ratio check using `Arith` operations
- Skip NLP when near-end detected
- Should fix CL3 with minimal code change

**Phase 2 (Later)**: Dual filter architecture
- Add Shadow filter with faster step size
- Selector logic (complicates fixed-point)
- **Tradeoff**: More accuracy vs more CPU/memory

**Phase 3 (Future)**: Per-band processing
- Requires FFT-based band splitting
- Higher computational cost
- May not fit on smaller ESP32 variants

## Decision

Given MCU constraints, implement **Phase 1 only** for now:
1. Fast near-end detection (fixed-point compatible)
2. Skip NLP when near-end detected
3. Verify CL3 passes
4. Verify E1 real-time quality

This balances quality improvement with resource constraints.

## References

- WebRTC AEC3: https://github.com/ewan-xu/AEC3
- Config: `echo_canceller3_config.h`
- Demo: `demo/demo.cc`
- Fixed-point arithmetic: `lib/pkg/audio/src/aec3/arithmetic.zig`
