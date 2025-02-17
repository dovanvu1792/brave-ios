// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.

import UIKit
import Social
import MobileCoreServices
import BraveShared

class ShareToBraveViewController: SLComposeServiceViewController {
    private struct Scheme {
            private enum SchemeType {
                case url, query
            }
            
            private let type: SchemeType
            private let urlOrQuery: String
            
            init?(item: NSSecureCoding) {
                if let text = item as? String {
                    if let url = URL(string: text)?.absoluteString {
                        urlOrQuery = url
                        type = .url
                    } else {
                        urlOrQuery = text
                        type = .query
                    }
                } else {
                    return nil
                }
            }
            
            var schemeUrl: URL? {
                var components = URLComponents()
                let queryItem: URLQueryItem
                
                components.scheme = "brave"
            
                switch type {
                case .url:
                    components.host = "open-url"
                    queryItem = URLQueryItem(name: "url", value: urlOrQuery)
                case .query:
                    components.host = "search"
                    queryItem = URLQueryItem(name: "q", value: urlOrQuery)
                }
                
                components.queryItems = [queryItem]
                return components.url
            }
        }
    
    // TODO: Separate scheme for debug builds, so it can be tested without need to uninstall production app.
    
    override func configurationItems() -> [Any]! {
        guard let inputItems = extensionContext?.inputItems as? [NSExtensionItem] else {
            return []
        }
        
        // Reduce all input items down to a single list of item providers
        let attachments: [NSItemProvider] = inputItems
            .compactMap { $0.attachments }
            .flatMap { $0 }
        
        // Look for the first URL the host application is sharing.
        // If there isn't a URL grab the first text item
        guard let provider = attachments.first(where: { $0.isText }) else {
            // If no item was processed. Cancel the share action to prevent the extension from locking the host application
            // due to the hidden ViewController.
            cancel()
            return []
        }

        provider.loadItem(forTypeIdentifier: String(kUTTypeText), options: nil) { item, error in
            guard let item = item, let schemeUrl = Scheme(item: item)?.schemeUrl else {
                self.cancel()
                return
             }
                        
            self.handleUrl(schemeUrl)
        }
        
        return []
    }
    
    private func handleUrl(_ url: URL) {
        // From http://stackoverflow.com/questions/24297273/openurl-not-work-in-action-extension
        var responder = self as UIResponder?
        while let strongResponder = responder {
            let selector = sel_registerName("openURL:")
            if strongResponder.responds(to: selector) {
                strongResponder.callSelector(selector, object: url as NSURL, delay: 0)
            }
            responder = strongResponder.next
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            self.cancel()
        }
    }
    
    override func viewDidAppear(_ animated: Bool) {
        // Stop keyboard from showing
        textView.resignFirstResponder()
        textView.isEditable = false
        
        super.viewDidAppear(animated)
    }
    
    override func willMove(toParent parent: UIViewController?) {
        view.alpha = 0
    }
}

extension NSItemProvider {
    var isText: Bool {
        return hasItemConformingToTypeIdentifier(String(kUTTypeText))
    }
}

extension NSObject {
    func callSelector(_ selector: Selector, object: AnyObject?, delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            Thread.detachNewThreadSelector(selector, toTarget: self, with: object)
        }
    }
}

