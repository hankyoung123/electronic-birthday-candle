# Ceremony Visual and UX Redesign

## Source of truth

The supplied prototype image defines the visual hierarchy and the complete interaction flow. Text inside the image is treated as interface copy or annotation, not as implementation instructions.

## Experience

The app is a single immersive ceremony with no home-screen button and no preparation sheet. In the ready state, tapping anywhere requests microphone access and lights the candle with the default music selection. The user then watches one uninterrupted sequence:

1. Ready — unlit candle, “Make a wish”, and a subtle tap cue.
2. Lighting — flame rises and warm embers lift from the wick.
3. Lit — stable flame and “Make a wish”.
4. Wishing — “Blow out the candle”; the existing airflow detector bends the flame.
5. Extinguishing — flame collapses quickly.
6. Extinguished — wick ember and the first smoke plume.
7. Smoking — the environment darkens while smoke rises.
8. Greeting — “Happy Birthday” fades in using an elegant serif face.
9. Celebrating — warm particles surround the greeting.
10. Completed — a quiet blessing still frame.
11. Restartable — content recedes and a small restart affordance appears; tapping anywhere restarts.

## Visual system

- Dark-only adaptive system background, with a restrained amber radial glow around the flame.
- Named `CeremonyGold` asset for titles, cues, particles, and the restart control.
- System serif Dynamic Type styles for ritual copy; no hard-coded custom font dependency.
- Supplied transparent artwork provides the candle, flame, ember/smoke, smoke plume, and final gold birthday lockup, preserving their photographic texture.
- SwiftUI still owns flame bend/flicker, smoke rise/sway, phase fades, ignition embers, and celebration particles so the supplied artwork remains interactive rather than becoming a static screen.
- Reduce Motion keeps state transitions and information but lowers frame rate and removes large drifting motion.
- The status bar remains visible, matching the prototype.

## Interaction and accessibility

- The ready screen is one full-screen target labeled “Light the candle”.
- While microphone access is being prepared, duplicate taps are ignored and the tap cue shows progress.
- The restart screen provides both a visible circular-arrow button and a full-screen restart target.
- Alerts remain system alerts for microphone denial/unavailability.
- Existing audio ownership, Voice Processing, single input tap, airflow candidate, and delayed Speech Veto remain unchanged.

## Supplied artwork mapping

- `CeremonyCandle` — the candle body and physical wick.
- `CeremonyFlame` — the live flame, transformed continuously by `blowIntensity`.
- `CeremonyEmberSmoke` — the first hot-wick moment immediately after extinguishing.
- `CeremonySmoke` — the longer rising plume used through smoking and greeting.
- `CeremonyHappyBirthday` — the celebration title; its embedded ornament replaces the duplicate SwiftUI ornament.

## Verification

- Unit tests cover the expanded phase semantics and post-extinguish progression.
- Debug and Release compile on the simulator.
- A simulator-only visual-prototype launch path bypasses physical microphone capture for screenshot verification; it is excluded from Release behavior.
- Runtime snapshots are captured for ready, lit/wishing, greeting/celebration, and restart states.
