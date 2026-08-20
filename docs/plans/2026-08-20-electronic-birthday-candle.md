# Electronic Birthday Candle Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build a polished iOS MVP that lets a user select local music, light one candle, make a wish, blow it out through the microphone, and receive a smoke-and-celebration ending.

**Architecture:** `CeremonySession` is the sole owner of ceremony state and legal transitions. SwiftUI views derive rendering from `CeremonyPhase`; `AudioEngine`, `BlowDetector`, and `HapticEngine` remain narrow system-capability services injected at the app root.

**Tech Stack:** Swift 6, SwiftUI, Observation, AVFoundation, Accelerate, UIKit haptics, XCTest; iOS 17+.

---

### Task 1: Project skeleton and authoritative state

**Files:**
- Create: `ElectronicBirthdayCandle.xcodeproj/project.pbxproj`
- Create: `BirthdayCandle/App/BirthdayCandleApp.swift`
- Create: `BirthdayCandle/Ceremony/CeremonyPhase.swift`
- Create: `BirthdayCandle/Ceremony/CeremonySession.swift`
- Create: `BirthdayCandle/UI/CeremonyView.swift`
- Create: `BirthdayCandle/Candle/CandleView.swift`
- Test: `BirthdayCandleTests/CeremonySessionTests.swift`

**Steps:** Define the legal phase graph first, add transition tests, wire one root-owned `@Observable` session, build the minimal dark candle screen, and verify the simulator build and targeted tests.

### Task 2: Programmatic flame

**Files:**
- Create: `BirthdayCandle/Candle/FlameView.swift`
- Modify: `BirthdayCandle/Candle/CandleView.swift`
- Modify: `BirthdayCandle/UI/CeremonyView.swift`

**Steps:** Replace the placeholder with a `TimelineView` + `Canvas` renderer composed of glow, outer flame, inner flame, and core. In debug builds expose a slider that continuously controls bend, size, and turbulence; verify build and simulator rendering.

### Task 3: Microphone and blow classification

**Files:**
- Create: `BirthdayCandle/Audio/BlowDetector.swift`
- Create: `BirthdayCandle/Audio/BlowDetectionConfiguration.swift`
- Create: `BirthdayCandle/Audio/AudioEngine.swift`
- Test: `BirthdayCandleTests/BlowDetectorTests.swift`

**Steps:** Write synthetic-signal tests for silence, speech-like energy, impulse, and sustained wind. Implement RMS + high-frequency ratio + attack/release smoothing behind one configuration type, then connect a microphone tap while keeping views hardware-agnostic.

### Task 4: Integrated extinguish sequence

**Files:**
- Modify: `BirthdayCandle/Ceremony/CeremonySession.swift`
- Create: `BirthdayCandle/Candle/SmokeView.swift`
- Modify: `BirthdayCandle/Candle/CandleView.swift`
- Test: `BirthdayCandleTests/CeremonySessionTests.swift`

**Steps:** Add strong-blow time integration in the session, transition through extinguishing/extinguished/celebrating, render wick ember and smoke from phase and elapsed time, and test that impulses cannot extinguish while sustained input can.

### Task 5: Local music and ceremony audio

**Files:**
- Create: `BirthdayCandle/Audio/MusicTrack.swift`
- Modify: `BirthdayCandle/Audio/AudioEngine.swift`
- Create: `BirthdayCandle/UI/MusicPicker.swift`
- Create: `BirthdayCandle/Resources/Audio/*.wav`

**Steps:** Add four original generated local tracks plus None, make the preparation sheet item-driven, play after ignition, lower volume during wishing, and fade to the ending after extinguish while microphone analysis remains active.

### Task 6: Semantic haptics

**Files:**
- Create: `BirthdayCandle/Haptics/HapticEngine.swift`
- Modify: `BirthdayCandle/Ceremony/CeremonySession.swift`

**Steps:** Add semantic ignite/wind/extinguish methods, rate-limit wind feedback, and verify the session never contains UIKit haptic patterns.

### Task 7: Polish and release verification

**Files:**
- Modify: `BirthdayCandle/UI/CeremonyView.swift`
- Modify: `BirthdayCandle/Candle/*.swift`
- Modify: `BirthdayCandle/Audio/AudioEngine.swift`
- Modify: `BirthdayCandle/Resources/Info.plist`

**Steps:** Finish typography, safe-area behavior, accessibility labels, reduced-motion handling, interruption/route recovery, and restart cleanup. Run the complete test target and a clean simulator build; document physical-device-only verification for microphone, speaker bleed, haptics, and interruptions.
