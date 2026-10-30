import Foundation
import Combine
import AVFoundation
import MediaPlayer
import UIKit

@MainActor
final class MusicPlayer: ObservableObject {
    typealias RepeatMode = PlaybackRepeatMode
    @Published private(set) var queueState = PlaybackQueue<Song>()
    var queue: [Song] { queueState.items }
    var index: Int { queueState.index }
    @Published private(set) var playing = false
    @Published private(set) var buffering = false
    @Published private(set) var elapsed = 0.0
    @Published private(set) var duration = 0.0
    @Published var repeatMode: RepeatMode = .off
    @Published var error: String?
    @Published private(set) var playbackFailed = false
    @Published private(set) var playbackID = UUID()
    @Published private(set) var recentSongs: [Song] = []
    @Published private(set) var sleepUntil: Date?
    private var sleepTask: Task<Void, Never>?
    private var interruptionSimulationTask: Task<Void, Never>?
    private let audio = AVPlayer()
    private var server: URL?
    private var timeToken: Any?
    private var endToken: NSObjectProtocol?
    private var failureToken: NSObjectProtocol?
    private var interruptionToken: NSObjectProtocol?
    private var routeToken: NSObjectProtocol?
    private var itemObservation: NSKeyValueObservation?
    private var playbackObservation: NSKeyValueObservation?
    private var resumeAfterInterruption = false
    private var artworkTask: Task<Void, Never>?
    private var artwork: MPMediaItemArtwork?
    private var seekInFlight = false
    private var seekID = UUID()
    private var hasEnded = false
    private var wantsPlayback = false
    var current: Song? { queueState.current }
    var canGoNext: Bool { queueState.canAdvance(repeatMode: repeatMode) }
    var canShuffle: Bool { queueState.upcomingCount > 1 }
    var playbackServer: URL? { server }
    var artworkProvider: ((Song, URL) -> [URL])?

    init() {
        // Keep a forward buffer in memory so short network stalls are less likely
        // to interrupt playback. AVPlayer manages and releases this buffer.
        audio.automaticallyWaitsToMinimizeStalling = true
        timeToken = audio.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] time in
            Task { @MainActor in
                guard let self else { return }
                let seconds = self.audio.currentTime().seconds
                if !self.seekInFlight { self.elapsed = seconds.isFinite ? max(0, seconds) : 0 }
                if let d = self.audio.currentItem?.duration.seconds, d.isFinite, d > 0, self.duration != d {
                    self.duration = d
                    self.updateRemoteAvailability()
                }
                self.publishNowPlaying()
            }
        }
        playbackObservation = audio.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] player, _ in
            Task { @MainActor in
                self?.playing = player.timeControlStatus != .paused
                self?.buffering = player.timeControlStatus == .waitingToPlayAtSpecifiedRate
                self?.publishNowPlaying()
            }
        }
        interruptionToken = NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let type = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let options = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            Task { @MainActor in
                guard let self else { return }
                if type == AVAudioSession.InterruptionType.began.rawValue {
                    self.resumeAfterInterruption = self.playing
                    self.pause()
                } else if type == AVAudioSession.InterruptionType.ended.rawValue {
                    if self.resumeAfterInterruption && AVAudioSession.InterruptionOptions(rawValue: options).contains(.shouldResume) { self.resume() }
                    self.resumeAfterInterruption = false
                }
            }
        }
        routeToken = NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            let reason = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            if reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue {
                Task { @MainActor in self?.pause() }
            }
        }
        installRemoteCommands()
    }

    func start(_ song: Song, within songs: [Song], server: URL) {
        guard let position = songs.firstIndex(where: { $0.id == song.id }), queueState.start(songs, at: position) else {
            error = "The selected song is no longer in this list. Refresh the library and try again."
            return
        }
        self.server = server
        loadCurrent()
    }

    func loadCurrent() {
        guard let song = current, let server else { return }
        wantsPlayback = true
        audio.pause()
        artworkTask?.cancel()
        playbackID = UUID()
        seekID = UUID()
        seekInFlight = false
        playbackFailed = false
        hasEnded = false
        elapsed = 0
        duration = song.duration_seconds ?? 0
        artwork = nil
        error = nil
        do {
            let url = try ServerAddress.mediaURL(for: song, server: server)
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
            if let token = endToken { NotificationCenter.default.removeObserver(token) }
            if let token = failureToken { NotificationCenter.default.removeObserver(token) }
            let item = AVPlayerItem(url: url)
            item.preferredForwardBufferDuration = 60
            itemObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
                Task { @MainActor in
                    guard let self, self.audio.currentItem === item else { return }
                    if item.status == .failed {
                        self.fail(item.error?.localizedDescription ?? "Unable to play this song. Check the MP3 file on your server.")
                    } else if item.status == .readyToPlay && self.wantsPlayback {
                        self.recentSongs.removeAll { $0.id == song.id }
                        self.recentSongs.insert(song, at: 0)
                        self.recentSongs = Array(self.recentSongs.prefix(30))
                    }
                }
            }
            endToken = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.audio.currentItem === item else { return }
                    // A truncated server response can look like a normal end to AVPlayer.
                    // Avoid skipping tracks when the stream ends well before catalog duration.
                    if let expected = song.duration_seconds, expected > 0 {
                        let actual = item.currentTime().seconds
                        if actual.isFinite, actual + 5 < expected {
                            self.fail("The audio stream ended early at \(Int(actual)) seconds. Check the song file or streaming response on your music server, then retry.")
                            return
                        }
                    }
                    self.next(automatic: true)
                }
            }
            failureToken = NotificationCenter.default.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main) { [weak self] note in
                let message = (note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error)?.localizedDescription
                Task { @MainActor in
                    guard let self, self.audio.currentItem === item else { return }
                    self.fail(message ?? "The stream stopped before the song ended. Retry playback or check your server connection.")
                }
            }
            audio.replaceCurrentItem(with: item)
            audio.play()
            playing = true
            publishNowPlaying()
            loadArtwork(song: song, server: server)
        } catch {
            pause()
            audio.replaceCurrentItem(with: nil)
            fail(error.localizedDescription)
        }
        updateRemoteAvailability()
    }

    func resume() {
        guard current != nil else { return }
        wantsPlayback = true
        if playbackFailed { loadCurrent(); return }
        guard let item = audio.currentItem, item.status != .failed else { loadCurrent(); return }
        do {
            try AVAudioSession.sharedInstance().setActive(true)
            if hasEnded {
                if duration > 0 { seek(0, resumeAfter: true) } else { loadCurrent() }
                return
            }
            audio.play()
            playing = true
            publishNowPlaying()
        } catch { self.error = error.localizedDescription }
    }
    func pause() {
        interruptionSimulationTask?.cancel()
        interruptionSimulationTask = nil
        wantsPlayback = false
        audio.pause()
        playing = false
        publishNowPlaying()
    }
    func clear() {
        pause()
        setSleepTimer(minutes: nil)
        recentSongs = []
        artworkTask?.cancel()
        if let token = endToken { NotificationCenter.default.removeObserver(token); endToken = nil }
        if let token = failureToken { NotificationCenter.default.removeObserver(token); failureToken = nil }
        itemObservation = nil
        audio.replaceCurrentItem(with: nil)
        queueState.clear()
        elapsed = 0
        duration = 0
        artwork = nil
        buffering = false
        playbackFailed = false
        seekInFlight = false
        hasEnded = false
        server = nil
        seekID = UUID()
        playbackID = UUID()
        error = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        updateRemoteAvailability()
    }
    func toggle() { playing ? pause() : resume() }
    func seek(_ seconds: Double, resumeAfter: Bool = false) {
        guard seconds.isFinite, duration > 0, let item = audio.currentItem else { return }
        hasEnded = false
        elapsed = max(0, min(seconds, duration))
        seekInFlight = true
        let operation = UUID()
        seekID = operation
        audio.seek(to: CMTime(seconds: elapsed, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            Task { @MainActor in
                guard let self, self.audio.currentItem === item, self.seekID == operation else { return }
                self.seekInFlight = false
                if finished && resumeAfter && self.wantsPlayback { self.resume() }
                self.publishNowPlaying()
            }
        }
        publishNowPlaying()
    }
    private func fail(_ message: String) {
        playbackFailed = true
        seekID = UUID()
        seekInFlight = false
        buffering = false
        pause()
        error = message
        updateRemoteAvailability()
    }
    func next(automatic: Bool = false) {
        if automatic && !wantsPlayback { hasEnded = true; return }
        switch queueState.advance(automatic: automatic, repeatMode: repeatMode) {
        case .changed: loadCurrent()
        case .restart:
            if duration > 0 { seek(0, resumeAfter: true) } else { loadCurrent() }
        case .finished: hasEnded = true; pause()
        case .unchanged: break
        }
        updateRemoteAvailability()
    }
    func previous() {
        switch queueState.previous(elapsed: elapsed) {
        case .changed: loadCurrent()
        case .restart: seek(0)
        default: break
        }
    }
    func jump(to position: Int) {
        guard queueState.jump(to: position) else { return }
        loadCurrent()
    }
    func addNext(_ song: Song, from source: URL) {
        guard prepareQueueSource(source) else { return }
        let empty = current == nil
        queueState.insertNext(song)
        if empty { loadCurrent() }
        updateRemoteAvailability()
    }
    func addToQueue(_ song: Song, from source: URL) {
        guard prepareQueueSource(source) else { return }
        let empty = current == nil
        queueState.append(song)
        if empty { loadCurrent() }
        updateRemoteAvailability()
    }
    private func prepareQueueSource(_ source: URL) -> Bool {
        if current != nil, server != source {
            error = "This queue belongs to a different music server. Play a song from the new server to start its queue."
            return false
        }
        server = source
        return true
    }
    func shuffleUpcoming() { queueState.shuffleUpcoming() }
    func removeUpcoming(at position: Int) { queueState.removeUpcoming(at: position); updateRemoteAvailability() }
    func moveUpcoming(from position: Int, to destination: Int) { queueState.moveUpcoming(from: position, to: destination); updateRemoteAvailability() }
    func clearHistory() { recentSongs = [] }
    func setSleepTimer(minutes: Int?) {
        sleepTask?.cancel()
        sleepUntil = nil
        guard let minutes, minutes > 0 else { return }
        sleepUntil = Date().addingTimeInterval(Double(minutes * 60))
        sleepTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(minutes) * 60 * 1_000_000_000) } catch { return }
            guard let self else { return }
            self.pause()
            self.sleepUntil = nil
        }
    }
    func simulateAudioInterruption(duration seconds: Int = 3) {
        interruptionSimulationTask?.cancel()
        guard playing else { return }
        pause()
        interruptionSimulationTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(max(1, seconds)) * 1_000_000_000) } catch { return }
            guard let self, !Task.isCancelled else { return }
            self.resume()
        }
    }
    func cycleRepeat() {
        switch repeatMode { case .off: repeatMode = .all; case .all: repeatMode = .one; case .one: repeatMode = .off }
        updateRemoteAvailability()
    }
    private func publishNowPlaying() {
        guard let song = current else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: song.externalPlaybackTitle,
            MPMediaItemPropertyArtist: song.artistName,
            MPMediaItemPropertyAlbumTitle: song.albumName,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed,
            MPNowPlayingInfoPropertyPlaybackRate: Double(audio.rate)
        ]
        if let artwork { info[MPMediaItemPropertyArtwork] = artwork }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
    private func loadArtwork(song: Song, server: URL) {
        artworkTask?.cancel()
        let generation = playbackID
        artworkTask = Task { [weak self] in
            guard let self else { return }
            let urls = self.artworkProvider?(song, server) ?? ServerAddress.coverURL(for: song, server: server).map { [$0] } ?? []
            for url in urls {
                guard !Task.isCancelled, self.playbackID == generation else { return }
                guard let image = await ArtworkLoader.shared.image(from: url) else { continue }
                guard !Task.isCancelled, self.playbackID == generation else { return }
                self.artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                self.publishNowPlaying()
                return
            }
        }
    }
    private func installRemoteCommands() {
        let c = MPRemoteCommandCenter.shared()
        c.playCommand.addTarget { [weak self] _ in guard self != nil else { return .noSuchContent }; Task { @MainActor in self?.resume() }; return .success }
        c.pauseCommand.addTarget { [weak self] _ in guard self != nil else { return .noSuchContent }; Task { @MainActor in self?.pause() }; return .success }
        c.togglePlayPauseCommand.addTarget { [weak self] _ in guard self != nil else { return .noSuchContent }; Task { @MainActor in self?.toggle() }; return .success }
        c.nextTrackCommand.addTarget { [weak self] _ in guard self != nil else { return .noSuchContent }; Task { @MainActor in self?.next() }; return .success }
        c.previousTrackCommand.addTarget { [weak self] _ in guard self != nil else { return .noSuchContent }; Task { @MainActor in self?.previous() }; return .success }
        c.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let position = event.positionTime
            Task { @MainActor in self?.seek(position) }
            return .success
        }
        updateRemoteAvailability()
    }
    private func updateRemoteAvailability() {
        let c = MPRemoteCommandCenter.shared()
        c.playCommand.isEnabled = current != nil
        c.pauseCommand.isEnabled = current != nil
        c.togglePlayPauseCommand.isEnabled = current != nil
        c.nextTrackCommand.isEnabled = canGoNext
        c.previousTrackCommand.isEnabled = current != nil
        c.changePlaybackPositionCommand.isEnabled = current != nil && duration > 0 && !playbackFailed
    }
}
