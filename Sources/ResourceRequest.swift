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
    
    public var key: ResourceKey {
        .init(url: url)
    }
    
    public let url: URL
    
    /// 自定义保存路径
    public let customSavePath: URL?
    
    /// 初始化优先级
    public let initialPriority: RequestPriority
    
    public let completion: ((ResourceDownloadResult) -> Void)?
    
    public let errorBlock: ((ResourceTransferError) -> Void)?
    
    public let progressBlock: ((Float) -> Void)?
    
    public init(
        url: URL,
        customSavePath: URL? = nil,
        priority: RequestPriority = .normal,
        completion: ((ResourceDownloadResult) -> Void)? = nil,
        errorBlock: ((ResourceTransferError) -> Void)? = nil,
        progressBlock: ((Float) -> Void)? = nil
    ) {
        self.url = url
        self.customSavePath = customSavePath
        self.initialPriority = priority
        self.completion = completion
        self.errorBlock = errorBlock
        self.progressBlock = progressBlock
    }
}

// MARK: - 便捷式开启下载
extension ResourceRequest {
    
    public func startLoad() {
        ResourceScheduler.default.load(request: self, subscriber: DownloadResultSubscriber())
    }
}

// MARK: - 便捷式取消下载
extension ResourceRequest {
    
    public func cancel() {
        ResourceScheduler.default.cancel(key: key)
    }
}
