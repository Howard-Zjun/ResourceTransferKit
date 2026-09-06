//
//  RT+UIImageView+Extension.swift
//  ResourceTransferDemo
//
//  Created by Howard-Zjun on 2026/9/4.
//

import UIKit

// MARK: - 图片便捷式入口
extension UIImageView {
    
    public func rt_load(
        resourceURL: URL,
        completion: ((ResourceDownloadResult) -> Void)? = nil,
        errorBlock: ((Error) -> Void)? = nil
    ) {
        let request = ResourceRequest(url: resourceURL, priority: .high) { [weak self] result in
            do {
                let data = try Data(contentsOf: result.localURL, options: [])
                if let image = UIImage(data: data) {
                    Task { @MainActor in
                        self?.image = image
                        completion?(result)
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
        ResourceScheduler.default.load(request: request, subscriber: DownloadResultImageSubscriber(imageView: self))
    }
    
    public func rt_cancel() {
        ResourceScheduler.default.cancel(subscriber: DownloadResultImageSubscriber(imageView: self))
    }
}
