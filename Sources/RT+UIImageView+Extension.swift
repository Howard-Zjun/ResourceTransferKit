//
//  RT+UIImageView+Extension.swift
//  ResourceTransferDemo
//
//  Created by Howard-Zjun on 2026/9/4.
//

import UIKit
import ObjectiveC

@MainActor
private enum ImageRequestAssociation {
    static var key: UInt8 = 0
}

private extension UIImageView {
    var rt_requestIdentifier: UUID? {
        get { objc_getAssociatedObject(self, &ImageRequestAssociation.key) as? UUID }
        set { objc_setAssociatedObject(self, &ImageRequestAssociation.key, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }
}

// MARK: - 图片便捷式入口
extension UIImageView {
    
    public func rt_load(
        resourceURL: URL,
        completion: ((ResourceDownloadResult) -> Void)? = nil,
        errorBlock: ((Error) -> Void)? = nil
    ) {
        let requestIdentifier = UUID()
        rt_requestIdentifier = requestIdentifier
        let request = ResourceRequest(url: resourceURL, priority: .high)
            .successBlock({ [weak self] result in
                guard self?.rt_requestIdentifier == requestIdentifier else { return }
                let localURL = result.localURL
                Task { @MainActor [weak self] in
                    do {
                        let image = try await Task.detached(priority: .userInitiated) {
                            let data = try Data(contentsOf: localURL)
                            guard let image = UIImage(data: data) else {
                                throw CocoaError(.fileReadCorruptFile)
                            }
                            return image.preparingForDisplay() ?? image
                        }.value
                        guard let self, self.rt_requestIdentifier == requestIdentifier else { return }
                        self.image = image
                        completion?(result)
                    } catch {
                        guard self?.rt_requestIdentifier == requestIdentifier else { return }
                        errorBlock?(error)
                    }
                }
            }).errorBlock { [weak self] error in
                guard self?.rt_requestIdentifier == requestIdentifier else { return }
                errorBlock?(error)
            }
        ResourceScheduler.default.load(request: request, subscriber: DownloadResultImageSubscriber(imageView: self))
    }
    
    public func rt_cancel() {
        rt_requestIdentifier = nil
        ResourceScheduler.default.cancel(subscriber: DownloadResultImageSubscriber(imageView: self))
    }
}
