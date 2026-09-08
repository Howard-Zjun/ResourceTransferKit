//
//  DownloadContext.swift
//  ResourceTransferDemo
//
//  Created by Howard-Zjun on 2026/9/4.
//

import UIKit

// MARK: - 下载上下文
final class DownloadContext {
    
    let key: ResourceKey
    
    /// 资源缓存地址
    let cacheFileURL: URL
    
    var subscribers: [DownloadSubscriber]
    
    weak var operation: DownloadOperation?
    
    var effectivePriority: RequestPriority
    
    let creationTime: Date
    
    var startDownloadTime: Date?
    
    /// 当前资源任务已消耗的失败重试次数，所有订阅者共享。
    var failRetryCount: Int = 0
    
    var state: TransferState = .waiting
    
    var progress: Float?
    
    var mimeType: String?
    
    var fileSize: Int64?
    
    init(request: ResourceRequest, subscriber: DownloadResultSubscriber, priority: RequestPriority) {
        self.key = request.key
        self.cacheFileURL = CacheStore.default.cacheFileURL(for: request.key)
        self.subscribers = [.init(request: request, resultSubscriber: subscriber)]
        self.effectivePriority = priority
        creationTime = .init()
    }
    
}

class DownloadSubscriber {
    
    let request: ResourceRequest
    
    let resultSubscriber: DownloadResultSubscriber
    
    init(request: ResourceRequest, resultSubscriber: DownloadResultSubscriber) {
        self.request = request
        self.resultSubscriber = resultSubscriber
    }
}
