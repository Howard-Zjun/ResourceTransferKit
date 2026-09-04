//
//  DownloadContext.swift
//  ResourceTransferDemo
//
//  Created by Howard-Zjun on 2026/9/4.
//

import UIKit

class DownloadSubscriber {
        
    let request: ResourceRequest
    
    weak var subscriberImageView: UIImageView?
    
    init(request: ResourceRequest, subscriberImageView: UIImageView? = nil) {
        self.request = request
        self.subscriberImageView = subscriberImageView
    }
}

// MARK: - 下载上下文
final class DownloadContext {
    
    let key: ResourceKey
    
    let destinationURL: URL
    
    var subscribers: [DownloadSubscriber]
    
    weak var operation: DownloadOperation?
    
    init(request: ResourceRequest, imgV: UIImageView) {
        self.key = request.key
        self.destinationURL = request.savePath
        self.subscribers = [.init(request: request, subscriberImageView: imgV)]
    }
}
