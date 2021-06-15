// Copyright 2021 The Brave Authors. All rights reserved.
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.

import Foundation
import BraveShared

class PlaylistDetailViewController: UIViewController, UIGestureRecognizerDelegate {
    
    private weak var playerView: VideoView?
    
    override func viewDidLoad() {
        super.viewDidLoad()

        setup()
        layoutBarButtons()
        addGestureRecognizers()
    }
    
    // MARK: Private
    
    private func setup() {
        view.backgroundColor = .black
                
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
    
    private func layoutBarButtons() {
        let exitBarButton =  UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(onExit(_:)))
        let sideListBarButton = UIBarButtonItem(image: #imageLiteral(resourceName: "playlist_split_navigation"), style: .done, target: self, action: #selector(onDisplayModeChange))
        
        navigationItem.rightBarButtonItem =
            PlayListSide(rawValue: Preferences.Playlist.listViewSide.value) == .left ? exitBarButton : sideListBarButton
        navigationItem.leftBarButtonItem =
            PlayListSide(rawValue: Preferences.Playlist.listViewSide.value) == .left ? sideListBarButton : exitBarButton
    }
    
    private func addGestureRecognizers() {
        let slideToRevealGesture = UISwipeGestureRecognizer(target: self, action: #selector(handleGesture))
        slideToRevealGesture.direction = PlayListSide(rawValue: Preferences.Playlist.listViewSide.value) == .left ? .right : .left
        
        view.addGestureRecognizer(slideToRevealGesture)
    }
    
    private func updateSplitViewDisplayMode(to displayMode: UISplitViewController.DisplayMode) {
        UIView.animate(withDuration: 0.2) {
            self.splitViewController?.preferredDisplayMode = displayMode
        }
    }
    
    // MARK: Actions
    
    func onSidePanelStateChanged() {
        onDisplayModeChange()
    }
    
    func onFullScreen() {
        navigationController?.setNavigationBarHidden(true, animated: true)
        
        if navigationController?.isNavigationBarHidden == true {
            splitViewController?.preferredDisplayMode = .secondaryOnly
        }
    }
    
    func onExitFullScreen() {
        navigationController?.setNavigationBarHidden(false, animated: true)
        
        if navigationController?.isNavigationBarHidden == true {
            splitViewController?.preferredDisplayMode = .primaryOverlay
        }
    }
        
    @objc
    private func onExit(_ button: UIBarButtonItem) {
        dismiss(animated: true, completion: nil)
    }
    
    @objc
    func handleGesture(gesture: UISwipeGestureRecognizer) {
        guard gesture.direction == .right,
              let playerView = playerView,
              !playerView.checkInsideTrackBar(point: gesture.location(in: view)) else {
            return
        }
        
       onDisplayModeChange()
    }
    
    @objc
    private func onDisplayModeChange() {
        updateSplitViewDisplayMode(
            to: splitViewController?.displayMode == .primaryOverlay ? .secondaryOnly : .primaryOverlay)
    }
    
    public func setVideoPlayer(_ videoPlayer: VideoView?) {
        if playerView?.superview == view {
            playerView?.removeFromSuperview()
        }
        
        playerView = videoPlayer
    }
    
    public func updateLayoutForMode(_ mode: UIUserInterfaceIdiom) {
        guard let playerView = playerView else { return }
        
        if mode == .pad {
            view.addSubview(playerView)
            playerView.snp.makeConstraints {
                $0.bottom.leading.trailing.equalTo(view)
                $0.top.equalTo(view.safeAreaLayoutGuide)
            }
        } else {
            if playerView.superview == view {
                playerView.removeFromSuperview()
            }
        }
    }
}
