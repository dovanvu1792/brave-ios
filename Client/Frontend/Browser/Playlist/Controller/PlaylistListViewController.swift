// Copyright 2021 The Brave Authors. All rights reserved.
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.

import Foundation
import MediaPlayer
import AVFoundation
import AVKit
import CoreData

// Third-Party
import SDWebImage

import BraveShared
import Shared
import Data

private let log = Logger.browserLogger

// MARK: - PlaylistListViewController

class PlaylistListViewController: UIViewController {
    // MARK: Constants
     
     struct Constants {
        static let playListCellIdentifier = "playlistCellIdentifier"
        static let tableRowHeight: CGFloat = 80
        static let tableHeaderHeight: CGFloat = 11
     }

    // MARK: Properties
    
    weak var delegate: PlaylistViewControllerDelegate?
    let playerView = VideoView()
    private let contentManager = MPPlayableContentManager.shared()
    private(set) lazy var mediaInfo = PlaylistMediaInfo(playerView: playerView)
    var currentlyPlayingItemIndex = -1
    private(set) var autoPlayEnabled = Preferences.Playlist.firstLoadAutoPlay.value
    var playerController: AVPlayerViewController?
    
    let activityIndicator = UIActivityIndicatorView(style: .medium).then {
        $0.isHidden = true
        $0.hidesWhenStopped = true
    }
    
    let tableView = UITableView(frame: .zero, style: .grouped).then {
        $0.backgroundView = UIView()
        $0.backgroundColor = .braveBackground
        $0.separatorColor = .clear
        $0.allowsSelectionDuringEditing = true
    }
    
    init() {
        super.init(nibName: nil, bundle: nil)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    deinit {
        if let playTime = playerView.player.currentItem?.currentTime(),
           Preferences.Playlist.playbackLeftOff.value {
            Preferences.Playlist.lastPlayedItemTime.value = playTime.seconds
        } else {
            Preferences.Playlist.lastPlayedItemTime.value = 0.0
        }
        
        playerView.pictureInPictureController?.delegate = nil
        playerView.pictureInPictureController?.stopPictureInPicture()
        playerView.stop()
        
        if let delegate = UIApplication.shared.delegate as? AppDelegate {
            if UIDevice.isIpad {
                playerView.attachLayer()
            }
            delegate.playlistRestorationController = nil
        }
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        PlaylistManager.shared.delegate = self
    
        setTheme()
        setup()

        fetchResults()
    }
    
    // MARK: Internal
    
    private func setTheme() {
        title = Strings.PlayList.playListSectionTitle

        view.backgroundColor = .braveBackground
        navigationController?.do {
            let appearance = UINavigationBarAppearance()
            appearance.configureWithTransparentBackground()
            appearance.titleTextAttributes = [.foregroundColor: UIColor.white]
            appearance.backgroundColor = .braveBackground
            
            $0.navigationBar.standardAppearance = appearance
            $0.navigationBar.barTintColor = UIColor.braveBackground
            $0.navigationBar.tintColor = .white
        }
    }
    
    private func setup () {
        tableView.do {
            $0.register(PlaylistCell.self, forCellReuseIdentifier: Constants.playListCellIdentifier)
            $0.dataSource = self
            $0.delegate = self
            $0.dragDelegate = self
            $0.dropDelegate = self
            $0.dragInteractionEnabled = true
        }
        
        playerView.delegate = self
    }
    
    private func fetchResults() {
        playerView.setControlsEnabled(playerView.player.currentItem != nil)
        updateTableBackgroundView()
        
        DispatchQueue.main.async {
            PlaylistManager.shared.reloadData()
            self.tableView.reloadData()
            self.contentManager.reloadData()
            
            if PlaylistManager.shared.numberOfAssets > 0 {
                self.playerView.setControlsEnabled(true)
                
                if let lastPlayedItemUrl = Preferences.Playlist.lastPlayedItemUrl.value, let index = PlaylistManager.shared.index(of: lastPlayedItemUrl) {
                    let indexPath = IndexPath(row: index, section: 0)
                    
                    self.playItem(at: indexPath, completion: { [weak self] error in
                        guard let self = self else { return }
                        
                        switch error {
                        case .error(let err):
                            log.error(err)
                            self.displayLoadingResourceError()
                        case .expired:
                            let item = PlaylistManager.shared.itemAtIndex(indexPath.row)
                            self.displayExpiredResourceError(item: item)
                        case .none:
                            let item = PlaylistManager.shared.itemAtIndex(indexPath.row)
                            guard let item = item else { return }
                            
                            let lastPlayedTime = Preferences.Playlist.lastPlayedItemTime.value
                            if item.pageSrc == Preferences.Playlist.lastPlayedItemUrl.value &&
                                lastPlayedTime > 0.0 &&
                                lastPlayedTime < self.playerView.player.currentItem?.duration.seconds ?? 0.0 &&
                                Preferences.Playlist.playbackLeftOff.value {
                                self.playerView.seek(to: Preferences.Playlist.lastPlayedItemTime.value)
                            }
                            
                            self.updateLastPlayedItem(indexPath: indexPath)
                        }
                    })
                } else {
                    self.tableView.delegate?.tableView?(self.tableView, didSelectRowAt: IndexPath(row: 0, section: 0))
                }
                
                self.autoPlayEnabled = true
            }
            
            self.updateTableBackgroundView()
        }
    }
    
    // MARK: Actions
    
    @objc
    private func onExit(_ button: UIBarButtonItem) {
        dismiss(animated: true, completion: nil)
    }
    
    override var preferredStatusBarStyle: UIStatusBarStyle {
        .lightContent
    }
    
    public func updateLayoutForMode(_ mode: UIUserInterfaceIdiom) {
        navigationItem.rightBarButtonItem = nil
        
        if mode == .phone {
            navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(onExit(_:)))
            
            playerView.setSidePanelHidden(true)
            
            // If the player view is in fullscreen, we should NOT change the tableView layout on rotation.
            view.addSubview(tableView)
            view.addSubview(playerView)
            playerView.addSubview(activityIndicator)
            
            if !playerView.isFullscreen {
                if UIDevice.current.orientation.isLandscape && UIDevice.isPhone {
                    playerView.setExitButtonHidden(false)
                    playerView.setFullscreenButtonHidden(true)
                    playerView.snp.remakeConstraints {
                        $0.edges.equalTo(view.snp.edges)
                    }
                    
                    activityIndicator.snp.remakeConstraints {
                        $0.center.equalToSuperview()
                    }
                } else {
                    playerView.setFullscreenButtonHidden(false)
                    playerView.setExitButtonHidden(true)
                    let videoPlayerHeight = (1.0 / 3.0) * (UIScreen.main.bounds.width > UIScreen.main.bounds.height ? UIScreen.main.bounds.width : UIScreen.main.bounds.height)

                    tableView.do {
                        $0.contentInset = UIEdgeInsets(top: videoPlayerHeight, left: 0.0, bottom: view.safeAreaInsets.bottom, right: 0.0)
                        $0.scrollIndicatorInsets = $0.contentInset
                        $0.contentOffset = CGPoint(x: 0.0, y: -videoPlayerHeight)
                        $0.isHidden = false
                    }
                    
                    playerView.snp.remakeConstraints {
                        $0.top.equalTo(view.safeArea.top)
                        $0.leading.trailing.equalToSuperview()
                        $0.height.equalTo(videoPlayerHeight)
                    }
                    
                    activityIndicator.snp.remakeConstraints {
                        $0.center.equalToSuperview()
                    }
                    
                    tableView.snp.remakeConstraints {
                        $0.edges.equalToSuperview()
                    }
                    
                    // On iPhone-8, 14.4, I need to scroll the tableView after setting its contentOffset and contentInset
                    // Otherwise the layout is broken when exiting fullscreen in portrait mode.
                    if PlaylistManager.shared.numberOfAssets > 0 {
                        tableView.scrollToRow(at: IndexPath(row: 0, section: 0), at: .top, animated: true)
                    }
                }
            } else {
                playerView.snp.remakeConstraints {
                    $0.edges.equalToSuperview()
                }
                
                activityIndicator.snp.remakeConstraints {
                    $0.center.equalToSuperview()
                }
            }
        } else {
            if splitViewController?.isCollapsed == true {
                playerView.setFullscreenButtonHidden(false)
                playerView.setExitButtonHidden(true)
                playerView.setSidePanelHidden(true)
            } else {
                playerView.setFullscreenButtonHidden(true)
                playerView.setExitButtonHidden(false)
                playerView.setSidePanelHidden(false)
            }
            
            view.addSubview(tableView)
            playerView.addSubview(activityIndicator)
            
            tableView.do {
                $0.contentInset = .zero
                $0.scrollIndicatorInsets = $0.contentInset
                $0.contentOffset = .zero
            }
            
            activityIndicator.snp.remakeConstraints {
                $0.center.equalToSuperview()
            }
            
            tableView.snp.remakeConstraints {
                $0.edges.equalToSuperview()
            }
        }
    }
    
    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)

        if UIDevice.isPhone && splitViewController?.isCollapsed == true {
            updateLayoutForMode(.phone)
            
            if !playerView.isFullscreen {
                navigationController?.setNavigationBarHidden(UIDevice.current.orientation.isLandscape, animated: true)
            }
        }
    }
}

extension PlaylistListViewController {
    func updateTableBackgroundView() {
        if PlaylistManager.shared.numberOfAssets > 0 {
            tableView.backgroundView = nil
            tableView.separatorStyle = .singleLine
        } else {
            let messageLabel = UILabel(frame: view.bounds).then {
                $0.text = Strings.PlayList.noItemLabelTitle
                $0.textColor = .white
                $0.numberOfLines = 0
                $0.textAlignment = .center
                $0.font = .systemFont(ofSize: 18.0, weight: .medium)
                $0.sizeToFit()
            }
            
            tableView.backgroundView = messageLabel
            tableView.separatorStyle = .none
        }
    }
}

extension PlaylistListViewController: UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        return !tableView.isEditing
    }
}

// MARK: VideoViewDelegate

extension PlaylistListViewController: VideoViewDelegate {
    func onPreviousTrack(isUserInitiated: Bool) {
        if currentlyPlayingItemIndex <= 0 {
            return
        }
        
        let index = currentlyPlayingItemIndex - 1
        if index < PlaylistManager.shared.numberOfAssets {
            let indexPath = IndexPath(row: index, section: 0)
            playItem(at: indexPath) { [weak self] error in
                guard let self = self else { return }
                switch error {
                case .error(let err):
                    log.error(err)
                    self.displayLoadingResourceError()
                case .expired:
                    let item = PlaylistManager.shared.itemAtIndex(index)
                    self.displayExpiredResourceError(item: item)
                case .none:
                    self.currentlyPlayingItemIndex = index
                    self.updateLastPlayedItem(indexPath: indexPath)
                }
            }
        }
    }
    
    func onNextTrack(isUserInitiated: Bool) {
        let assetCount = PlaylistManager.shared.numberOfAssets
        let isAtEnd = currentlyPlayingItemIndex >= assetCount - 1
        var index = currentlyPlayingItemIndex
        
        switch playerView.repeatState {
        case .none:
            if isAtEnd {
                playerView.pictureInPictureController?.delegate = nil
                playerView.pictureInPictureController?.stopPictureInPicture()
                playerView.stop()
                
                if let delegate = UIApplication.shared.delegate as? AppDelegate {
                    if UIDevice.isIpad {
                        playerView.attachLayer()
                    }
                    delegate.playlistRestorationController = nil
                }
                return
            }
            index += 1
        case .repeatOne:
            playerView.seek(to: 0.0)
            playerView.play()
            return
        case .repeatAll:
            index = isAtEnd ? 0 : index + 1
        }
        
        if index >= 0 {
            let indexPath = IndexPath(row: index, section: 0)
            playItem(at: indexPath) { [weak self] error in
                guard let self = self else { return }
                switch error {
                case .error(let err):
                    log.error(err)
                    self.displayLoadingResourceError()
                case .expired:
                    if isUserInitiated || self.playerView.repeatState == .repeatOne || assetCount <= 1 {
                        let item = PlaylistManager.shared.itemAtIndex(index)
                        self.displayExpiredResourceError(item: item)
                    } else {
                        DispatchQueue.main.async {
                            self.currentlyPlayingItemIndex = index
                            self.onNextTrack(isUserInitiated: isUserInitiated)
                        }
                    }
                case .none:
                    self.currentlyPlayingItemIndex = index
                    self.updateLastPlayedItem(indexPath: indexPath)
                }
            }
        }
    }
    
    func onPictureInPicture(enabled: Bool) {
        playerView.pictureInPictureController?.delegate = enabled ? self : nil
    }
    
    func onSidePanelStateChanged() {
        delegate?.onSidePanelStateChanged()
    }
    
    func onFullScreen() {
        if !UIDevice.isIpad || splitViewController?.isCollapsed == true {
            navigationController?.setNavigationBarHidden(true, animated: true)
            tableView.isHidden = true
            playerView.snp.remakeConstraints {
                $0.edges.equalToSuperview()
            }
        } else {
            delegate?.onFullscreen()
        }
    }
    
    func onExitFullScreen() {
        if UIDevice.isIpad && splitViewController?.isCollapsed == false {
            playerView.setFullscreenButtonHidden(true)
            playerView.setExitButtonHidden(false)
            splitViewController?.parent?.dismiss(animated: true, completion: nil)
        } else if UIDevice.isIpad && splitViewController?.isCollapsed == true {
            navigationController?.setNavigationBarHidden(false, animated: true)
            playerView.setFullscreenButtonHidden(true)
            updateLayoutForMode(.phone)
        } else if UIDevice.current.orientation.isPortrait {
            navigationController?.setNavigationBarHidden(false, animated: true)
            tableView.isHidden = false
            updateLayoutForMode(.phone)
        } else {
            playerView.setFullscreenButtonHidden(true)
            playerView.setExitButtonHidden(false)
            splitViewController?.parent?.dismiss(animated: true, completion: nil)
        }
    }
}

// MARK: - PlaylistManagerDelegate

extension PlaylistListViewController: PlaylistManagerDelegate {
    func onDownloadProgressUpdate(id: String, percentComplete: Double) {
        guard let index = PlaylistManager.shared.index(of: id) else {
            return
        }
         
        let indexPath = IndexPath(row: index, section: 0)
        guard let cell = tableView.cellForRow(at: IndexPath(row: index, section: 0)) as? PlaylistCell else {
            return
        }
        
        // Cell is not visible, do not update percentages
        if tableView.indexPathsForVisibleRows?.contains(indexPath) == false {
            return
        }
        
        guard let item = PlaylistManager.shared.itemAtIndex(index) else {
            return
        }
        
        switch PlaylistManager.shared.state(for: id) {
        case .inProgress:
            cell.durationFetcher = getAssetDurationFormatted(item: item) { [weak cell] in
                cell?.detailLabel.text = "\($0) - \(Int(percentComplete))% \(Strings.PlayList.savedForOfflineLabelTitle)"
            }
        case .downloaded:
            if let itemSize = PlaylistManager.shared.sizeOfDownloadedItem(for: item.pageSrc) {
                cell.durationFetcher = getAssetDurationFormatted(item: item) { [weak cell] in
                    cell?.detailLabel.text = "\($0) - \(itemSize)"
                }
            } else {
                cell.durationFetcher = getAssetDurationFormatted(item: item) { [weak cell] in
                    cell?.detailLabel.text = "\($0) - \(Strings.PlayList.savedForOfflineLabelTitle)"
                }
            }
        case .invalid:
            cell.durationFetcher = getAssetDurationFormatted(item: item) { [weak cell] in
                cell?.detailLabel.text = $0
            }
        }
    }
    
    func onDownloadStateChanged(id: String, state: PlaylistDownloadManager.DownloadState, displayName: String?, error: Error?) {
        guard let index = PlaylistManager.shared.index(of: id) else {
            return
        }
         
        let indexPath = IndexPath(row: index, section: 0)
        guard let cell = tableView.cellForRow(at: IndexPath(row: index, section: 0)) as? PlaylistCell else {
            return
        }
        
        // Cell is not visible, do not update status
        if tableView.indexPathsForVisibleRows?.contains(indexPath) == false {
            return
        }
        
        guard let item = PlaylistManager.shared.itemAtIndex(index) else {
            return
        }
            
        if let error = error {
            log.error("Error downloading playlist item: \(error)")
            
            cell.durationFetcher = getAssetDurationFormatted(item: item) { [weak cell] in
                cell?.detailLabel.text = $0
            }
            
            let alert = UIAlertController(title: Strings.PlayList.playlistSaveForOfflineErrorTitle,
                                          message: Strings.PlayList.playlistSaveForOfflineErrorMessage, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: Strings.PlayList.okayButtonTitle, style: .default, handler: nil))
            self.present(alert, animated: true, completion: nil)
        } else {
            switch state {
            case .inProgress:
                cell.durationFetcher = getAssetDurationFormatted(item: item) { [weak cell] in
                    cell?.detailLabel.text = "\($0) - \(Strings.PlayList.savingForOfflineLabelTitle)"
                }
            case .downloaded:
                if let itemSize = PlaylistManager.shared.sizeOfDownloadedItem(for: item.pageSrc) {
                    cell.durationFetcher = getAssetDurationFormatted(item: item) { [weak cell] in
                        cell?.detailLabel.text = "\($0) - \(itemSize)"
                    }
                } else {
                    cell.durationFetcher = getAssetDurationFormatted(item: item) { [weak cell] in
                        cell?.detailLabel.text = "\($0) - \(Strings.PlayList.savedForOfflineLabelTitle)"
                    }
                }
            case .invalid:
                cell.durationFetcher = getAssetDurationFormatted(item: item) { [weak cell] in
                    cell?.detailLabel.text = $0
                }
            }
        }
    }
    
    func controllerDidChange(_ anObject: Any, at indexPath: IndexPath?, for type: NSFetchedResultsChangeType, newIndexPath: IndexPath?) {
        
        if tableView.hasActiveDrag || tableView.hasActiveDrop { return }
        
        switch type {
            case .insert:
                guard let newIndexPath = newIndexPath else { break }
                tableView.insertRows(at: [newIndexPath], with: .fade)
            case .delete:
                guard let indexPath = indexPath else { break }
                tableView.deleteRows(at: [indexPath], with: .fade)
            case .update:
                guard let indexPath = indexPath else { break }
                tableView.reloadRows(at: [indexPath], with: .fade)
            case .move:
                guard let indexPath = indexPath,
                      let newIndexPath = newIndexPath else { break }
                tableView.deleteRows(at: [indexPath], with: .fade)
                tableView.insertRows(at: [newIndexPath], with: .fade)
            default:
                break
        }
    }
    
    func controllerDidChangeContent() {
        if tableView.hasActiveDrag || tableView.hasActiveDrop { return }
        tableView.endUpdates()
    }
    
    func controllerWillChangeContent() {
        if tableView.hasActiveDrag || tableView.hasActiveDrop { return }
        tableView.beginUpdates()
    }
}
