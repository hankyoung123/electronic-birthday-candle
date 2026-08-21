import Foundation

struct TrackStyle {
    let name: String
    /// Melody as (semitone degree above C4, duration in beats).
    let melody: [(Int, Double)]
    let chords: [[Int]]
    let tempo: Double
    let octaveShift: Int
    let decay: Double
    let harmonics: [(Double, Double)]
}

let outputDirectory = CommandLine.arguments.dropFirst().first ?? "BirthdayCandle/Resources/Audio"
try FileManager.default.createDirectory(atPath: outputDirectory, withIntermediateDirectories: true)

// “Happy Birthday to You” in C major — the four famous phrases.
// Ratios: q = quarter (1 beat), e = eighth (0.5), q. = dotted quarter (1.5).
let happyBirthday: [(Int, Double)] = [
    // “Happy birthday to you” — G G A G C· B
    (7, 0.5), (7, 0.5), (9, 0.5), (7, 0.5), (12, 1.5), (11, 1.0),
    // “Happy birthday to you” — G G A G D· C
    (7, 0.5), (7, 0.5), (9, 0.5), (7, 0.5), (14, 1.5), (12, 1.0),
    // “Happy birthday dear …” — G G G'· E' C B A·
    (7, 0.5), (7, 0.5), (19, 1.5), (16, 1.0), (12, 1.0), (11, 1.0), (9, 1.5),
    // “Happy birthday to you” — F· F E C D· C·
    (17, 1.5), (17, 1.0), (16, 1.0), (12, 1.0), (14, 1.5), (12, 1.5),
]
let progression = [[0, 4, 7], [5, 9, 12], [7, 11, 14], [0, 4, 7]] // C, F, G, C
let styles = [
    TrackStyle(name: "classic", melody: happyBirthday, chords: progression, tempo: 104, octaveShift: 0, decay: 1.8, harmonics: [(1, 1), (2, 0.22), (3, 0.10)]),
    TrackStyle(name: "piano", melody: happyBirthday, chords: progression, tempo: 88, octaveShift: -12, decay: 5.2, harmonics: [(1, 1), (2, 0.35), (3, 0.17), (4, 0.07)]),
    TrackStyle(name: "music-box", melody: happyBirthday, chords: progression, tempo: 112, octaveShift: 12, decay: 7.5, harmonics: [(1, 1), (3, 0.34), (5, 0.14)]),
    TrackStyle(name: "jazz", melody: happyBirthday, chords: [[0, 4, 7, 11], [5, 9, 12, 16], [7, 11, 14, 17], [0, 4, 7, 11]], tempo: 116, octaveShift: -5, decay: 3.1, harmonics: [(1, 1), (2, 0.28), (3, 0.09)])
]

let sampleRate = 22_050

for style in styles {
    let beat = 60 / style.tempo
    let totalBeats = happyBirthday.reduce(0) { $0 + $1.1 }
    let totalBeatsInt = Int(ceil(totalBeats))
    let duration = beat * Double(totalBeatsInt)
    var samples = [Double](repeating: 0, count: Int(duration * Double(sampleRate)))

    var cursor = 0.0
    for note in style.melody {
        addNote(
            midi: 60 + note.0 + style.octaveShift,
            start: cursor * beat,
            duration: note.1 * beat,
            gain: 0.20,
            decay: style.decay,
            harmonics: style.harmonics,
            samples: &samples
        )
        cursor += note.1
    }

    for beatIndex in 0..<totalBeatsInt {
        let chord = style.chords[(beatIndex / 4) % style.chords.count]
        for semitone in chord {
            addNote(
                midi: 48 + semitone,
                start: Double(beatIndex) * beat,
                duration: beat * 1.3,
                gain: 0.035,
                decay: 1.4,
                harmonics: [(1, 1), (2, 0.1)],
                samples: &samples
            )
        }
    }

    try writeWAV(samples: normalize(samples, peak: 0.76), name: style.name)
}

var extinguish = [Double](repeating: 0, count: Int(1.1 * Double(sampleRate)))
var noiseState: UInt64 = 0xC0FFEE
for index in extinguish.indices {
    noiseState = noiseState &* 6_364_136_223_846_793_005 &+ 1
    let noise = Double((noiseState >> 40) & 0xFFFF) / Double(0xFFFF) * 2 - 1
    let progress = Double(index) / Double(extinguish.count)
    extinguish[index] = noise * pow(1 - progress, 3.2) * 0.38
}
try writeWAV(samples: extinguish, name: "extinguish")

var celebration = [Double](repeating: 0, count: Int(3.2 * Double(sampleRate)))
for (index, midi) in [60, 64, 67, 72, 76].enumerated() {
    addNote(midi: midi, start: Double(index) * 0.18, duration: 2.2, gain: 0.19, decay: 2.1, harmonics: [(1, 1), (2, 0.21), (3, 0.08)], samples: &celebration)
}
try writeWAV(samples: normalize(celebration, peak: 0.8), name: "celebration")

func addNote(
    midi: Int,
    start: Double,
    duration: Double,
    gain: Double,
    decay: Double,
    harmonics: [(Double, Double)],
    samples: inout [Double]
) {
    let frequency = 440 * pow(2, Double(midi - 69) / 12)
    let startIndex = max(Int(start * Double(sampleRate)), 0)
    let endIndex = min(Int((start + duration) * Double(sampleRate)), samples.count)
    guard startIndex < endIndex else { return }

    for index in startIndex..<endIndex {
        let time = Double(index - startIndex) / Double(sampleRate)
        let attack = min(time / 0.018, 1)
        let envelope = attack * exp(-time * decay)
        var value = 0.0
        for (multiple, level) in harmonics {
            value += sin(2 * .pi * frequency * multiple * time) * level
        }
        samples[index] += value * envelope * gain
    }
}

func normalize(_ samples: [Double], peak: Double) -> [Double] {
    let currentPeak = samples.map(abs).max() ?? 1
    guard currentPeak > 0 else { return samples }
    let scale = min(peak / currentPeak, 1)
    return samples.map { $0 * scale }
}

func writeWAV(samples: [Double], name: String) throws {
    let bytesPerSample = 2
    let dataSize = samples.count * bytesPerSample
    var data = Data()
    data.appendASCII("RIFF")
    data.appendLE(UInt32(36 + dataSize))
    data.appendASCII("WAVEfmt ")
    data.appendLE(UInt32(16))
    data.appendLE(UInt16(1))
    data.appendLE(UInt16(1))
    data.appendLE(UInt32(sampleRate))
    data.appendLE(UInt32(sampleRate * bytesPerSample))
    data.appendLE(UInt16(bytesPerSample))
    data.appendLE(UInt16(16))
    data.appendASCII("data")
    data.appendLE(UInt32(dataSize))
    for sample in samples {
        data.appendLE(Int16(max(-1, min(sample, 1)) * Double(Int16.max)))
    }
    try data.write(to: URL(fileURLWithPath: outputDirectory).appendingPathComponent("\(name).wav"))
}

extension Data {
    mutating func appendASCII(_ string: String) {
        append(string.data(using: .ascii)!)
    }

    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }
}