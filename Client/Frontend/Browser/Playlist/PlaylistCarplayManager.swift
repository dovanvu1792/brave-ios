// Copyright 2021 The Brave Authors. All rights reserved.
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.

import Foundation
import MediaPlayer
import CarPlay
import AVKit

import SDWebImage
import Shared
import Data

class PlaylistCarplayManager: NSObject {
    private let contentManager = MPPlayableContentManager.shared()
    public let videoView = VideoView()
    private let mediaInfo: PlaylistMediaInfo
    private let backgroundFrc = PlaylistItem.backgroundFrc()
    
    override init() {
        mediaInfo = PlaylistMediaInfo(playerView: videoView)
        super.init()
        
        contentManager.delegate = self
        contentManager.dataSource = self
        
        DispatchQueue.main.async {
            PlaylistManager.shared.reloadData()
            self.contentManager.beginUpdates()
            self.contentManager.endUpdates()
            self.contentManager.reloadData()
        }
        
        MPRemoteCommandCenter.shared().pauseCommand.addTarget { [weak self] _ in
            guard let self = self else { return .commandFailed }
            MPNowPlayingInfoCenter.default().playbackState = self.videoView.isPlaying ? .playing : .paused
            return .success
        }
        
        MPRemoteCommandCenter.shared().playCommand.addTarget { [weak self] _ in
            guard let self = self else { return .commandFailed }
            MPNowPlayingInfoCenter.default().playbackState = self.videoView.isPlaying ? .playing : .paused
            return .success
        }
        
        MPRemoteCommandCenter.shared().stopCommand.addTarget { [weak self] _ in
            guard let self = self else { return .commandFailed }
            MPNowPlayingInfoCenter.default().playbackState = self.videoView.isPlaying ? .playing : .paused
            return .success
        }
    }
    
    private func ensureMainThreadSync<T>(execute work: () throws -> T) rethrows -> T {
        if Thread.current.isMainThread {
            return try work()
        } else {
            return try DispatchQueue.main.sync { try work() }
        }
    }
}

extension PlaylistCarplayManager: MPPlayableContentDelegate {
    func playableContentManager(_ contentManager: MPPlayableContentManager, didUpdate context: MPPlayableContentManagerContext) {
        
        if context.endpointAvailable || AVAudioSession.sharedInstance().currentRoute.outputs.first?.portType == .carAudio {
            // CarPlay
            print("CAR PLAY CONNECTED")
        } else {
            print("CAR PLAY DISCONNECTED")
        }
    }
    
    func playableContentManager(_ contentManager: MPPlayableContentManager, initiatePlaybackOfContentItemAt indexPath: IndexPath, completionHandler: @escaping (Error?) -> Void) {
        
        if indexPath.count == 2 {
            // Item Section
            ensureMainThreadSync {
                let mediaItem = PlaylistManager.shared.itemAtIndex(indexPath.item)
                self.contentManager.nowPlayingIdentifiers = [mediaItem.name]

                mediaInfo.loadMediaItem(mediaItem, index: indexPath.item) { error in
                    switch error {
                    case .none:
                        MPNowPlayingInfoCenter.default().playbackState = .playing
                        completionHandler(nil)
                    case .expired:
                        MPNowPlayingInfoCenter.default().playbackState = .stopped
                        completionHandler(Strings.PlayList.expiredAlertDescription)
                    case .error(let error):
                        MPNowPlayingInfoCenter.default().playbackState = .stopped
                        completionHandler(error)
                    }
                }
            }
        } else {
            // Tab Section
            completionHandler(nil)
        }
        
        // Workaround to see carplay NowPlaying on the simulator
        #if targetEnvironment(simulator)
        ensureMainThreadSync {
            UIApplication.shared.endReceivingRemoteControlEvents()
            UIApplication.shared.beginReceivingRemoteControlEvents()
        }
        #endif
    }
    
    func beginLoadingChildItems(at indexPath: IndexPath, completionHandler: @escaping (Error?) -> Void) {
        completionHandler(nil)
    }
}

extension PlaylistCarplayManager: MPPlayableContentDataSource {
    func numberOfChildItems(at indexPath: IndexPath) -> Int {
        if indexPath.indices.count == 0 {
            return 1 // 1 Tab.
        }
        
        return ensureMainThreadSync {
            return PlaylistManager.shared.numberOfAssets
        }
    }
    
    func childItemsDisplayPlaybackProgress(at indexPath: IndexPath) -> Bool {
        true
    }
    
    func contentItem(at indexPath: IndexPath) -> MPContentItem? {
        // Tab Section
        if indexPath.count == 1 {
            let item = MPContentItem(identifier: "BravePlaylist")
            item.title = "Brave Playlist"
            item.isContainer = true
            item.isPlayable = false
            let imageIcon = #imageLiteral(resourceName: "settings-shields")
            item.artwork = MPMediaItemArtwork(boundsSize: imageIcon.size, requestHandler: { _ -> UIImage in
                return imageIcon
            })
            return item
        }
        
        if indexPath.count == 2 {
            // Items section
            return ensureMainThreadSync {
                let mediaItem = PlaylistManager.shared.itemAtIndex(indexPath.item)
                let cacheState = PlaylistManager.shared.state(for: mediaItem.pageSrc)
                let item = MPContentItem(identifier: mediaItem.name)
                item.title = mediaItem.name
                item.subtitle = mediaItem.pageSrc
                item.isPlayable = true
                item.isStreamingContent = cacheState != .downloaded
                loadThumbnail(item: mediaItem, contentItem: item)
                return item
            }
        }
        
        return nil
    }
}

extension PlaylistCarplayManager {
    private func loadThumbnail(item: PlaylistInfo, contentItem: MPContentItem) {
        guard let url = URL(string: item.src) else { return }
        
        if let cachedImage = SDImageCache.shared.imageFromCache(forKey: url.absoluteString) {
            contentItem.artwork = MPMediaItemArtwork(boundsSize: cachedImage.size, requestHandler: { _ -> UIImage in
                return cachedImage
            })
            
            contentItem.thumbnailGenerator = nil
            return
        }
        
        // Loading from Cache failed, attempt to fetch HLS thumbnail
        contentItem.thumbnailGenerator = HLSThumbnailGenerator(url: url, time: 3, completion: { [weak self, weak contentItem] image, error in
            guard let self = self, let contentItem = contentItem else { return }
            
            contentItem.thumbnailGenerator = nil
            
            if let image = image {
                contentItem.artwork = MPMediaItemArtwork(boundsSize: image.size, requestHandler: { _ -> UIImage in
                    return image
                })
                contentItem.thumbnailGenerator = nil
                SDImageCache.shared.store(image, forKey: url.absoluteString, completion: nil)
            } else {
                // We can fall back to AVAssetImageGenerator or FavIcon
                self.loadThumbnailFallbackImage(item: item, contentItem: contentItem)
            }
        })
    }
    
    // Fall back to AVAssetImageGenerator
    // If that fails, fallback to FavIconFetcher
    private func loadThumbnailFallbackImage(item: PlaylistInfo, contentItem: MPContentItem) {
        guard let url = URL(string: item.src) else { return }

        let time = CMTimeMake(value: 3, timescale: 1)
        contentItem.imageAssetGenerator = AVAssetImageGenerator(asset: AVAsset(url: url))
        contentItem.imageAssetGenerator?.appliesPreferredTrackTransform = false
        contentItem.imageAssetGenerator?.generateCGImagesAsynchronously(forTimes: [NSValue(time: time)]) { [weak contentItem] _, cgImage, _, result, error in
            guard let contentItem = contentItem else { return }
            
            contentItem.imageAssetGenerator = nil
            if result == .succeeded, let cgImage = cgImage {
                let image = UIImage(cgImage: cgImage)

                DispatchQueue.main.async {
                    contentItem.artwork = MPMediaItemArtwork(boundsSize: image.size, requestHandler: { _ -> UIImage in
                        return image
                    })
                    SDImageCache.shared.store(image, forKey: url.absoluteString, completion: nil)
                }
            } else {
                guard let url = URL(string: item.pageSrc) else { return }
                
                DispatchQueue.main.async {
                    contentItem.favIconFetcher = FavIconImageRenderer()
                    contentItem.favIconFetcher?.loadIcon(siteURL: url) { icon in
                        defer { contentItem.favIconFetcher = nil }
                        guard let icon = icon else {
                            contentItem.artwork = nil
                            return
                        }
                        
                        contentItem.artwork = MPMediaItemArtwork(boundsSize: icon.size, requestHandler: { _ -> UIImage in
                            return icon
                        })
                    }
                }
            }
        }
    }
}

extension MPContentItem {
    private struct AssociatedKeys {
        static var thumbnailGenerator: Int = 0
        static var imageAssetGenerator: Int = 0
        static var favIconFetcher: Int = 0
    }
    
    var thumbnailGenerator: HLSThumbnailGenerator? {
        get { objc_getAssociatedObject(self, &AssociatedKeys.thumbnailGenerator) as? HLSThumbnailGenerator }
        set { objc_setAssociatedObject(self, &AssociatedKeys.thumbnailGenerator, newValue, .OBJC_ASSOCIATION_ASSIGN) }
    }
    
    var imageAssetGenerator: AVAssetImageGenerator? {
        get { objc_getAssociatedObject(self, &AssociatedKeys.imageAssetGenerator) as? AVAssetImageGenerator }
        set { objc_setAssociatedObject(self, &AssociatedKeys.imageAssetGenerator, newValue, .OBJC_ASSOCIATION_ASSIGN) }
    }
    
    var favIconFetcher: FavIconImageRenderer? {
        get { objc_getAssociatedObject(self, &AssociatedKeys.favIconFetcher) as? FavIconImageRenderer }
        set { objc_setAssociatedObject(self, &AssociatedKeys.favIconFetcher, newValue, .OBJC_ASSOCIATION_ASSIGN) }
    }
}

class FavIconImageRenderer {
    private var task: DispatchWorkItem?
    
    deinit {
        task?.cancel()
    }

    func loadIcon(siteURL: URL, completion: ((UIImage?) -> Void)?) {
        task?.cancel()
        task = DispatchWorkItem {
            let faviconFetcher: FaviconFetcher? = FaviconFetcher(siteURL: siteURL, kind: .favicon, domain: nil)
            faviconFetcher?.load() { [weak self] _, attributes in
                guard let self = self,
                      let cancellable = self.task,
                      !cancellable.isCancelled  else {
                    completion?(nil)
                    return
                }
                
                if let image = attributes.image {
                    let finalImage = self.renderOnImageContext { context, rect in
                        if let backgroundColor = attributes.backgroundColor {
                            context.setFillColor(backgroundColor.cgColor)
                        }
                        
                        if let image = image.cgImage {
                            context.draw(image, in: rect)
                        }
                    }
                    
                    completion?(finalImage)
                } else {
                    // Monogram favicon attributes
                    let label = UILabel().then {
                        $0.textColor = .white
                        $0.backgroundColor = .clear
                        $0.minimumScaleFactor = 0.5
                    }
                    
                    label.text = FaviconFetcher.monogramLetter(
                        for: siteURL,
                        fallbackCharacter: nil
                    )
                    
                    let finalImage = self.renderOnImageContext { context, _ in
                        label.layer.render(in: context)
                    }
                    
                    completion?(finalImage)
                }
            }
        }
    }
    
    private func renderOnImageContext(_ draw: (CGContext, CGRect) -> Void) -> UIImage? {
        let size = CGSize(width: 100.0, height: 100.0)
        UIGraphicsBeginImageContextWithOptions(size, false, 0.0)
        draw(UIGraphicsGetCurrentContext()!, CGRect(size: size))
        let img = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        return img
    }
}
