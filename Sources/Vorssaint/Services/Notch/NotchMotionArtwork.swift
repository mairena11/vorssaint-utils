// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import AVFoundation
import SwiftUI

@MainActor
final class NotchMotionArtworkPlayer: ObservableObject {
    static let shared = NotchMotionArtworkPlayer()

    @Published private(set) var ready = false
    let player = AVPlayer()

    private struct TrackKey: Equatable, Hashable {
        let sourceBundle: String
        let sourcePID: Int32?
        let item: String?
        let title: String
        let artist: String
        let album: String

        init(_ playback: NotchPlayback, sourcePID: Int32?) {
            sourceBundle = playback.track.appBundleIdentifier ?? ""
            self.sourcePID = sourcePID ?? playback.track.appPID
            item = playback.itemIdentifier
            title = playback.track.title ?? ""
            artist = playback.track.artist ?? ""
            album = playback.track.album ?? ""
        }

        var albumSignature: String {
            "\(sourceBundle)|\(sourcePID ?? 0)|\(NotchMotionArtworkResolver.normalizedAlbum(album))|\(artist.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current))"
        }
    }

    private struct CacheEntry {
        let result: Result<(NotchMotionArtworkAlbum, NotchMotionArtworkAsset), Error>
        let expires: Date
    }

    private var currentPlayback: NotchPlayback?
    private var sourcePID: Int32?
    private var trackKey: TrackKey?
    private var activeAlbum: NotchMotionArtworkAlbum?
    private var visible = false
    private var reduceMotion = false
    private var pending: Task<Void, Never>?
    private var generation = UUID()
    private var statusObservation: NSKeyValueObservation?
    private var endedObserver: NSObjectProtocol?
    private var powerTimer: Timer?
    private var cache: [String: CacheEntry] = [:]
    private var failedItems: [TrackKey: Date] = [:]

    private init() {
        player.isMuted = true
        player.actionAtItemEnd = .pause
        powerTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.reconcilePowerPolicy() }
        }
    }

    func update(playback: NotchPlayback?, sourcePID: Int32?, visible: Bool, reduceMotion: Bool) {
        self.visible = visible
        self.reduceMotion = reduceMotion
        currentPlayback = playback
        self.sourcePID = sourcePID
        guard visible, !reduceMotion else {
            cancelCurrentRequest()
            ready = false
            player.pause()
            return
        }
        guard let playback else {
            reset()
            return
        }
        let nextKey = TrackKey(playback, sourcePID: sourcePID)
        failedItems = failedItems.filter { $0.value > Date() }
        if trackKey == nextKey {
            reconcilePowerPolicy()
            if !ready, pending == nil, failedItems[nextKey].map({ $0 > Date() }) != true,
               playback.track.appBundleIdentifier == "com.apple.Music" {
                startResolution(for: playback, key: nextKey)
            }
            return
        }

        let canReuseCandidate = trackKey?.albumSignature == nextKey.albumSignature && activeAlbum != nil
        trackKey = nextKey
        cancelCurrentRequest()
        if canReuseCandidate {
            ready = false
            player.pause()
        } else {
            stopCurrentItem()
        }
        guard playback.track.appBundleIdentifier == "com.apple.Music" else { return }
        startResolution(for: playback, key: nextKey)
    }

    /// The shared player may still be holding the previous cover for a frame
    /// during a fast skip. Show motion only for the exact current recording.
    func isReady(for playback: NotchPlayback, sourcePID: Int32?) -> Bool {
        ready && trackKey == TrackKey(playback, sourcePID: sourcePID)
    }

    func setVisible(_ visible: Bool) {
        self.visible = visible
        if !visible {
            cancelCurrentRequest()
            ready = false
        } else if let playback = currentPlayback, let trackKey, !ready,
                  failedItems[trackKey].map({ $0 > Date() }) != true,
                  !reduceMotion, playback.track.appBundleIdentifier == "com.apple.Music" {
            startResolution(for: playback, key: trackKey)
        }
        reconcilePowerPolicy()
    }

    private func startResolution(for playback: NotchPlayback, key: TrackKey) {
        let requestID = UUID()
        generation = requestID
        let lookupKey = [key.sourceBundle, key.sourcePID.map(String.init) ?? "", key.item ?? "",
                         key.title, key.artist, key.album].joined(separator: "\u{1f}")
        let now = Date()
        if let cached = cache[lookupKey], cached.expires > now {
            switch cached.result {
            case .success(let value): accept(value.0, asset: value.1, requestID: requestID, key: key)
            case .failure:
                generation = UUID()
                stopCurrentItem()
            }
            return
        }
        pending = Task { [weak self] in
            do {
                let value = try await NotchMotionArtworkResolver.resolve(playback)
                guard !Task.isCancelled, let self, self.generation == requestID else { return }
                self.cache[lookupKey] = CacheEntry(result: .success(value), expires: Date().addingTimeInterval(3_600))
                self.trimCache()
                self.pending = nil
                self.accept(value.album, asset: value.asset, requestID: requestID, key: key)
            } catch {
                guard !Task.isCancelled, let self, self.generation == requestID else { return }
                self.cache[lookupKey] = CacheEntry(result: .failure(error), expires: Date().addingTimeInterval(300))
                self.trimCache()
                self.pending = nil
                self.stopCurrentItem()
            }
        }
    }

    private func accept(_ album: NotchMotionArtworkAlbum, asset: NotchMotionArtworkAsset,
                        requestID: UUID, key: TrackKey) {
        guard generation == requestID, trackKey?.albumSignature == key.albumSignature, visible, !reduceMotion else { return }
        if activeAlbum == album, player.currentItem != nil {
            statusObservation = nil
            if let endedObserver {
                NotificationCenter.default.removeObserver(endedObserver)
                self.endedObserver = nil
            }
            activeAlbum = album
            ready = player.currentItem?.status == .readyToPlay
            observeCurrentItem(requestID: requestID, key: key)
            reconcilePowerPolicy()
            return
        }
        let item = AVPlayerItem(url: asset.videoURL)
        item.preferredPeakBitRate = 2_000_000
        item.preferredForwardBufferDuration = 3
        activeAlbum = album
        player.replaceCurrentItem(with: item)
        observe(item, requestID: requestID, key: key)
        reconcilePowerPolicy()
    }

    private func observeCurrentItem(requestID: UUID, key: TrackKey) {
        guard let item = player.currentItem else { return }
        observe(item, requestID: requestID, key: key)
    }

    private func observe(_ item: AVPlayerItem, requestID: UUID, key: TrackKey) {
        statusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            Task { @MainActor in
                guard let self, self.generation == requestID else { return }
                if item.status == .readyToPlay {
                    self.ready = true
                    self.reconcilePowerPolicy()
                } else if item.status == .failed {
                    self.failedItems[key] = Date().addingTimeInterval(300)
                    self.stopCurrentItem()
                }
            }
        }
        endedObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.generation == requestID else { return }
                    self.player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                        Task { @MainActor in
                            guard let self, self.generation == requestID else { return }
                            self.reconcilePowerPolicy()
                        }
                    }
                }
            }
    }

    private func reconcilePowerPolicy() {
        let thermal = ProcessInfo.processInfo.thermalState
        let powerAllowsMotion = !ProcessInfo.processInfo.isLowPowerModeEnabled
            && thermal != .serious && thermal != .critical
        guard visible, !reduceMotion, powerAllowsMotion, currentPlayback?.isPlaying == true, ready else {
            player.pause()
            return
        }
        player.play()
    }

    private func trimCache() {
        while cache.count > 64, let oldest = cache.min(by: { $0.value.expires < $1.value.expires })?.key {
            cache.removeValue(forKey: oldest)
        }
    }

    private func cancelCurrentRequest() {
        pending?.cancel()
        pending = nil
        generation = UUID()
    }

    private func stopCurrentItem() {
        player.pause()
        statusObservation = nil
        if let endedObserver {
            NotificationCenter.default.removeObserver(endedObserver)
            self.endedObserver = nil
        }
        player.replaceCurrentItem(with: nil)
        ready = false
        activeAlbum = nil
    }

    private func reset() {
        cancelCurrentRequest()
        stopCurrentItem()
        trackKey = nil
        currentPlayback = nil
        failedItems.removeAll()
    }
}

struct NotchMotionArtworkView: View {
    let image: NSImage?
    let size: CGFloat
    let playback: NotchPlayback
    let sourcePID: Int32?
    let enabled: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var motion = NotchMotionArtworkPlayer.shared

    var body: some View {
        ZStack {
            NotchArtwork(image: image, size: size, source: playback.track)
            if enabled && playback.isPlaying && !reduceMotion,
               motion.isReady(for: playback, sourcePID: sourcePID) {
                NotchMotionArtworkSurface(player: motion.player)
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: size * 0.19, style: .continuous))
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .frame(width: size, height: size)
        .onAppear { sync(visible: enabled) }
        .onChange(of: playback) { sync(visible: enabled) }
        .onChange(of: sourcePID) { sync(visible: enabled) }
        .onChange(of: reduceMotion) { sync(visible: enabled) }
        .onChange(of: enabled) {
            if enabled {
                sync(visible: true)
            } else {
                motion.update(playback: playback, sourcePID: sourcePID, visible: false, reduceMotion: reduceMotion)
            }
        }
        .onDisappear {
            motion.update(playback: playback, sourcePID: sourcePID, visible: false, reduceMotion: reduceMotion)
        }
    }

    private func sync(visible: Bool) {
        guard enabled else { return }
        motion.update(playback: playback, sourcePID: sourcePID, visible: visible, reduceMotion: reduceMotion)
    }
}

private struct NotchMotionArtworkSurface: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> NotchMotionArtworkLayerView {
        let view = NotchMotionArtworkLayerView()
        view.playerLayer.player = player
        return view
    }

    func updateNSView(_ view: NotchMotionArtworkLayerView, context: Context) {
        view.playerLayer.player = player
    }

    static func dismantleNSView(_ view: NotchMotionArtworkLayerView, coordinator: ()) {
        view.playerLayer.player = nil
    }
}

private final class NotchMotionArtworkLayerView: NSView {
    let playerLayer = AVPlayerLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        playerLayer.videoGravity = .resizeAspect
        layer?.addSublayer(playerLayer)
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
    }
}
