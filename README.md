# Electronic Birthday Candle

A minimal iOS 17+ SwiftUI ceremony: choose a local track, light the candle, make a wish, and blow into the microphone to extinguish the flame.

## Open and run

1. Open `ElectronicBirthdayCandle.xcodeproj` in Xcode.
2. Select the `BirthdayCandle` scheme and an iPhone device.
3. Run, tap **Start**, select music, then tap **Light the Candle**.
4. Grant microphone access and blow continuously toward the iPhone microphone.

The simulator supports the visual flow and logic tests, but microphone response, speaker bleed, haptics, output volume, route changes, and interruption recovery must be tuned on a physical iPhone.

## Tests

```sh
xcodebuild \
  -project ElectronicBirthdayCandle.xcodeproj \
  -scheme BirthdayCandle \
  -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  test
```

All blow thresholds live in `BlowDetectionConfiguration`. The bundled music and effects are original procedural audio; regenerate them with:

```sh
swift Scripts/generate-audio.swift BirthdayCandle/Resources/Audio
```
