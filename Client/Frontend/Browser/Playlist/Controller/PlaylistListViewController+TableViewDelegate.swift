// Copyright 2021 The Brave Authors. All rights reserved.
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.

import Foundation
import UIKit
import BraveShared
import Shared
import Data

private let log = Logger.browserLogger

// MARK: UITableViewDelegate

extension PlaylistListViewController: UITableViewDelegate {
    
    func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        
        if indexPath.row < 0 || indexPath.row >= PlaylistManager.shared.numberOfAssets {
            return nil
        }

        guard let currentItem = PlaylistManager.shared.itemAtIndex(indexPath.row) else {
            return nil
        }
        
        let cacheState = PlaylistManager.shared.state(for: currentItem.pageSrc)
        
        let cacheAction = UIContextualAction(style: .normal, title: nil, handler: { [weak self] (action, view, completionHandler) in
            guard let self = self else { return }
            
            switch cacheState {
                case .inProgress:
                    PlaylistManager.shared.cancelDownload(item: currentItem)
                    tableView.reloadRows(at: [indexPath], with: .automatic)
                case .invalid:
                    if PlaylistManager.shared.isDiskSpaceEncumbered() {
                        let style: UIAlertController.Style = UIDevice.current.userInterfaceIdiom == .pad ? .alert : .actionSheet
                        let alert = UIAlertController(
                            title: Strings.PlayList.playlistDiskSpaceWarningTitle, message: Strings.PlayList.playlistDiskSpaceWarningMessage, preferredStyle: style)
                        
                        alert.addAction(UIAlertAction(title: Strings.OKString, style: .default, handler: { _ in
                            PlaylistManager.shared.download(item: currentItem)
                            tableView.reloadRows(at: [indexPath], with: .automatic)
                        }))
                        
                        alert.addAction(UIAlertAction(title: Strings.CancelString, style: .cancel, handler: nil))
                        self.present(alert, animated: true, completion: nil)
                    } else {
                        PlaylistManager.shared.download(item: currentItem)
                        tableView.reloadRows(at: [indexPath], with: .automatic)
                    }
                case .downloaded:
                    let style: UIAlertController.Style = UIDevice.current.userInterfaceIdiom == .pad ? .alert : .actionSheet
                    let alert = UIAlertController(
                        title: Strings.PlayList.removePlaylistOfflineDataAlertTitle, message: Strings.PlayList.removePlaylistOfflineDataAlertMessage, preferredStyle: style)
                    
                    alert.addAction(UIAlertAction(title: Strings.PlayList.removeActionButtonTitle, style: .destructive, handler: { _ in
                        _ = PlaylistManager.shared.deleteCache(item: currentItem)
                        tableView.reloadRows(at: [indexPath], with: .automatic)
                    }))
                    
                    alert.addAction(UIAlertAction(title: Strings.cancelButtonTitle, style: .cancel, handler: nil))
                    self.present(alert, animated: true, completion: nil)
            }
            
            completionHandler(true)
        })
        
        let deleteAction = UIContextualAction(style: .normal, title: nil, handler: { [weak self] (action, view, completionHandler) in
            guard let self = self else { return }
            
            let style: UIAlertController.Style = UIDevice.current.userInterfaceIdiom == .pad ? .alert : .actionSheet
            let alert = UIAlertController(
                title: Strings.PlayList.removePlaylistVideoAlertTitle, message: Strings.PlayList.removePlaylistVideoAlertMessage, preferredStyle: style)
            
            alert.addAction(UIAlertAction(title: Strings.PlayList.removeActionButtonTitle, style: .destructive, handler: { _ in
                PlaylistManager.shared.delete(item: currentItem)

                if self.currentlyPlayingItemIndex == indexPath.row {
                    self.currentlyPlayingItemIndex = -1
                    self.mediaInfo.nowPlayingInfo = nil
                    self.mediaInfo.updateNowPlayingMediaArtwork(image: nil)
                    
                    self.updateTableBackgroundView()
                    self.playerView.resetVideoInfo()
                    self.activityIndicator.stopAnimating()
                    self.playerView.stop()
                }
            }))
            
            alert.addAction(UIAlertAction(title: Strings.cancelButtonTitle, style: .cancel, handler: nil))
            self.present(alert, animated: true, completion: nil)
            
            completionHandler(true)
        })

        cacheAction.image = cacheState == .invalid ? #imageLiteral(resourceName: "playlist_download") : #imageLiteral(resourceName: "playlist_delete_download")
        cacheAction.backgroundColor = #colorLiteral(red: 0.4509803922, green: 0.4784313725, blue: 0.8705882353, alpha: 1)
        
        deleteAction.image = #imageLiteral(resourceName: "playlist_delete_item")
        deleteAction.backgroundColor = #colorLiteral(red: 0.9176470588, green: 0.2274509804, blue: 0.05098039216, alpha: 1)
        
        return UISwipeActionsConfiguration(actions: [deleteAction, cacheAction])
    }
    
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        if tableView.isEditing {
            tableView.setEditing(false, animated: true)
            return
        }
        
        playItem(at: indexPath, completion: { [weak self] error in
            guard let self = self else { return }
            
            switch error {
            case .error(let err):
                log.error(err)
                self.displayLoadingResourceError()
            case .expired:
                let item = PlaylistManager.shared.itemAtIndex(indexPath.row)
                self.displayExpiredResourceError(item: item)
            case .none:
                self.updateLastPlayedItem(indexPath: indexPath)
            }
        })
    }
    
    func playItem(at indexPath: IndexPath, completion: ((PlaylistMediaInfo.MediaPlaybackError) -> Void)?) {
        guard indexPath.row < PlaylistManager.shared.numberOfAssets,
           let item = PlaylistManager.shared.itemAtIndex(indexPath.row) else {
            return
        }
        
        activityIndicator.startAnimating()
        activityIndicator.isHidden = false
        currentlyPlayingItemIndex = indexPath.row
        
        let selectedCell = tableView.cellForRow(at: indexPath) as? PlaylistCell
        playerView.setVideoInfo(videoDomain: item.pageSrc, videoTitle: item.pageTitle)
        mediaInfo.updateNowPlayingMediaArtwork(image: selectedCell?.thumbnailView.image)
        
        playerView.stop()
        
        mediaInfo.loadMediaItem(item, index: indexPath.row, autoPlayEnabled: autoPlayEnabled) { [weak self] error in
            guard let self = self else { return }
            defer { completion?(error) }
            self.activityIndicator.stopAnimating()
            
            switch error {
            case .error:
                break
                
            case .expired:
                selectedCell?.detailLabel.text = Strings.PlayList.expiredLabelTitle
                
            case .none:
                let mediaItem = self.playerView.player.currentItem ?? self.playerView.pendingMediaItem
                log.debug("Playing Live Video: \(mediaItem?.duration.isIndefinite ?? false)")
            }
        }
    }
    
    func updateLastPlayedItem(indexPath: IndexPath) {
        guard let item = PlaylistManager.shared.itemAtIndex(indexPath.row) else {
            return
        }
        
        Preferences.Playlist.lastPlayedItemUrl.value = item.pageSrc
        
        if let playTime = self.playerView.player.currentItem?.currentTime(),
           Preferences.Playlist.playbackLeftOff.value {
            Preferences.Playlist.lastPlayedItemTime.value = playTime.seconds
        } else {
            Preferences.Playlist.lastPlayedItemTime.value = 0.0
        }
    }
    
    func displayExpiredResourceError(item: PlaylistInfo?) {
        if let item = item {
            let alert = UIAlertController(title: Strings.PlayList.expiredAlertTitle,
                                          message: Strings.PlayList.expiredAlertDescription, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: Strings.PlayList.reopenButtonTitle, style: .default, handler: { _ in
                
                if let url = URL(string: item.pageSrc) {
                    self.dismiss(animated: true, completion: nil)
                    (UIApplication.shared.delegate as? AppDelegate)?.browserViewController.openURLInNewTab(url, isPrivileged: false)
                }
            }))
            alert.addAction(UIAlertAction(title: Strings.cancelButtonTitle, style: .cancel, handler: nil))
            self.present(alert, animated: true, completion: nil)
        } else {
            let alert = UIAlertController(title: Strings.PlayList.expiredAlertTitle,
                                          message: Strings.PlayList.expiredAlertDescription, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: Strings.OKString, style: .default, handler: nil))
            self.present(alert, animated: true, completion: nil)
        }
    }
    
    func displayLoadingResourceError() {
        let alert = UIAlertController(
            title: Strings.PlayList.sorryAlertTitle, message: Strings.PlayList.loadResourcesErrorAlertDescription, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: Strings.PlayList.okayButtonTitle, style: .default, handler: nil))
        
        self.present(alert, animated: true, completion: nil)
    }
}
