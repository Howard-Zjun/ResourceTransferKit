//
//  ResourceRequest.swift
//  ResourceTransferDemo
//
//  Created by Howard-Zjun on 2026/9/4.
//

import UIKit

public enum RequestPriority: Int, Comparable {
    case low
    case normal
    case high
    
    public static func < (lhs: RequestPriority, rhs: RequestPriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

// MARK: - 请求参数封装
public struct ResourceRequest {

    let identifier = UUID()
    
    public var key: ResourceKey {
        .init(url: url)
    }
    
    public let url: URL
    
    /// 自定义保存路径
    public let customSavePath: URL?
    
    /// 初始化优先级
    public let initialPriority: RequestPriority
    
    /// 同一个资源失败后允许重新进入调度队列的最大次数，范围为 0...5，默认值为 3。
    public let maxFailRetryCount: Int
    
    public let completion: (@MainActor (ResourceDownloadResult) -> Void)?
    
    public let errorBlock: (@MainActor (ResourceTransferError) -> Void)?
    
    public let progressBlock: (@MainActor (Float) -> Void)?
    
    public init(
        url: URL,
        customSavePath: URL? = nil,
        priority: RequestPriority = .normal,
        maxFailRetryCount: Int = 3,
        completion: (@MainActor (ResourceDownloadResult) -> Void)? = nil,
        errorBlock: (@MainActor (ResourceTransferError) -> Void)? = nil,
        progressBlock: (@MainActor (Float) -> Void)? = nil
    ) {
        self.url = url
        self.customSavePath = customSavePath
        self.initialPriority = priority
        self.maxFailRetryCount = min(max(0, maxFailRetryCount), 5)
        self.completion = completion
        self.errorBlock = errorBlock
        self.progressBlock = progressBlock
    }
}

// MARK: - 便捷式入口
extension ResourceRequest {
    
    public func startLoad() {
        ResourceScheduler.default.load(request: self, subscriber: DownloadResultSubscriber())
    }
    
    public func cancel() {
        ResourceScheduler.default.cancel(request: self)
    }
    
    public func pause() {
        // TODO: - 阶段5开发
    }
    
    public func resume(){
        // TODO: - 阶段5开发
    }
}
