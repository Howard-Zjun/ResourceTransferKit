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
    
    var effectivePriority: RequestPriority
    
    let creationTime: Date
    
    init(request: ResourceRequest, imgV: UIImageView, priority: RequestPriority) {
        self.key = request.key
        self.destinationURL = request.savePath
        self.subscribers = [.init(request: request, subscriberImageView: imgV)]
        self.effectivePriority = priority
        creationTime = .init()
    }
}

enum RequestPriority: Int, Comparable {
    case low
    case normal
    case high
    
    static func < (lhs: RequestPriority, rhs: RequestPriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}
