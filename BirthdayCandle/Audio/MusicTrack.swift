struct MusicTrack: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let resourceName: String

    static let classic = MusicTrack(id: "classic", title: "Classic", resourceName: "classic")
    static let piano = MusicTrack(id: "piano", title: "Piano", resourceName: "piano")
    static let musicBox = MusicTrack(id: "music-box", title: "Music Box", resourceName: "music-box")
    static let jazz = MusicTrack(id: "jazz", title: "Jazz", resourceName: "jazz")

    static let all: [MusicTrack] = [.classic, .piano, .musicBox, .jazz]
}
