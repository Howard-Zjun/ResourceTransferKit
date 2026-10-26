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
    public let priority: RequestPriority
    
    /// 同一个资源失败后允许重新进入调度队列的最大次数，范围为 0...5，默认值为 3。
    public let maxFailRetryCount: Int

    /// 资源存在于有效缓存时是否直接使用缓存结果；默认开启。
    public let usesCacheIfAvailable: Bool
    
    public init(
        url: URL,
        customSavePath: URL? = nil,
        priority: RequestPriority = .normal,
        maxFailRetryCount: Int = 3,
        usesCacheIfAvailable: Bool = true,
    ) {
        self.url = url
        self.customSavePath = customSavePath
        self.priority = priority
        self.maxFailRetryCount = min(max(0, maxFailRetryCount), 5)
        self.usesCacheIfAvailable = usesCacheIfAvailable
    }
    
    public static func make(
        url: URL,
        customSavePath: URL? = nil,
        priority: RequestPriority = .normal,
        maxFailRetryCount: Int = 3,
        usesCacheIfAvailable: Bool = true,
        subscriber: AnyObject? = nil
    ) -> DownloadResultSubscriber {
        let resource = ResourceRequest(url: url, customSavePath: customSavePath, priority: priority, maxFailRetryCount: maxFailRetryCount, usesCacheIfAvailable: usesCacheIfAvailable)
        return DownloadResultSubscriber(resource: resource, subscriber: subscriber)
    }
}
