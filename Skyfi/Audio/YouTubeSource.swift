import Foundation
import YouTubeKit

/// Finds a playable audio URL for a YouTube video on the device.
/// Live streams come back as an HLS manifest; normal videos as the best audio-only stream.
enum YouTubeSource {
    struct Resolved {
        let url: URL
        let title: String?
        let isLive: Bool
    }

    enum ResolveError: LocalizedError {
        case noAudio

        var errorDescription: String? { "Couldn't find audio for this video." }
    }

    static func resolve(videoID: String) async throws -> Resolved {
        let video = YouTube(videoID: videoID, methods: [.local, .remote])
        let title = try? await video.metadata?.title

        if let live = try? await video.livestreams.first(where: { $0.streamType == .hls }) {
            return Resolved(url: live.url, title: title, isLive: true)
        }

        let streams = try await video.streams
        let audio = streams.filterAudioOnly()
        let pick = audio.filter { $0.isNativelyPlayable }.highestAudioBitrateStream()
            ?? audio.filter { $0.fileExtension == .m4a }.highestAudioBitrateStream()
            ?? streams.filterVideoAndAudio().filter { $0.isNativelyPlayable }.lowestResolutionStream()
        guard let pick else { throw ResolveError.noAudio }
        return Resolved(url: pick.url, title: title, isLive: false)
    }
}
