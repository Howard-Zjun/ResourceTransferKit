//
//  RT+UIImageView+Extension.swift
//  ResourceTransferDemo
//
//  Created by Howard-Zjun on 2026/9/4.
//

import UIKit

// MARK: - 图片便捷设置入口
extension UIImageView {
    
    public func rt_load(
        resourceURL: URL,
        completion: ((URL) -> Void)? = nil,
        errorBlock: ((Error) -> Void)? = nil
    ) {
        let request = ImageResourceRequest(url: resourceURL) { [weak self] localResourceURL in
            do {
                let data = try Data(contentsOf: localResourceURL, options: [])
                if let image = UIImage(data: data) {
                    Task { @MainActor in
                        self?.image = image
                        completion?(localResourceURL)
                    }
                }
            } catch {
                Task { @MainActor in
                    errorBlock?(error)
                }
            }
        } errorBlock: { error in
            Task { @MainActor in
                errorBlock?(error)
            }
        }
        ImageResourceDownloader.default.load(imageRequest: request, imageView: self)
    }
    
    public func rt_cancel() {
        ImageResourceDownloader.default.cancel(imageView: self)
    }
}
