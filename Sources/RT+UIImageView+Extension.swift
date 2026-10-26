//
//  RT+UIImageView+Extension.swift
//  ResourceTransferDemo
//
//  Created by Howard-Zjun on 2026/9/4.
//

import UIKit
import ObjectiveC

private enum AssociatedKeys {
    static var resourceURL: UInt8 = 0
}

// MARK: - 图片便捷式入口
extension UIImageView {
    
    public func rt_load(
        resourceURL: URL,
        completion: ((ResourceDownloadResult) -> Void)? = nil,
        errorBlock: ((Error) -> Void)? = nil
    ) {
        rt_cancel()
        
        let subscriber = ResourceRequest.make(url: resourceURL, priority: .high)
        let identifier = subscriber.identifier
        subscriber.successBlock { [weak self] result in
            guard let self,
                  let current = objc_getAssociatedObject(self, &AssociatedKeys.resourceURL) as? DownloadResultSubscriber,
                  current.identifier == identifier else { return }
            objc_setAssociatedObject(self, &AssociatedKeys.resourceURL, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            guard let image = UIImage(contentsOfFile: result.localURL.path) else {
                errorBlock?(ResourceTransferError.underlying(CocoaError(.fileReadCorruptFile)))
                return
            }
            self.image = image
            completion?(result)
        }.errorBlock { [weak self] error in
            guard let self,
                  let current = objc_getAssociatedObject(self, &AssociatedKeys.resourceURL) as? DownloadResultSubscriber,
                  current.identifier == identifier else { return }
            objc_setAssociatedObject(self, &AssociatedKeys.resourceURL, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            errorBlock?(error)
        }
        
        objc_setAssociatedObject(self, &AssociatedKeys.resourceURL, subscriber, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        subscriber.load()
    }
    
    public func rt_cancel() {
        guard let lastSubscriber = objc_getAssociatedObject(self, &AssociatedKeys.resourceURL) as? DownloadResultSubscriber else {
            return
        }
        objc_setAssociatedObject(self, &AssociatedKeys.resourceURL, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        lastSubscriber.cancel()
    }
}
