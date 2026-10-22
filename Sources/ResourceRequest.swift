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

public typealias SuccessBlock = @MainActor (ResourceDownloadResult) -> Void
public typealias ErrorBlock = @MainActor (ResourceTransferError) -> Void
public typealias ProgressBlock = @MainActor (Float) -> Void

// MARK: - 请求参数封装
public class ResourceRequest {

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

    /// 资源存在于有效缓存时是否直接使用缓存结果；默认开启。
    public let usesCacheIfAvailable: Bool
    
    private var successBlocks: [SuccessBlock] = []
    
    private var errorBlock: [ErrorBlock] = []
    
    private var progressBlock: [ProgressBlock] = []
    
    public init(
        url: URL,
        customSavePath: URL? = nil,
        priority: RequestPriority = .normal,
        maxFailRetryCount: Int = 3,
        usesCacheIfAvailable: Bool = true,
    ) {
        self.url = url
        self.customSavePath = customSavePath
        self.initialPriority = priority
        self.maxFailRetryCount = min(max(0, maxFailRetryCount), 5)
        self.usesCacheIfAvailable = usesCacheIfAvailable
    }
    
    @MainActor
    public func successBlock(_ block: @escaping SuccessBlock) -> ResourceRequest {
        successBlocks.append(block)
        return self
    }
    
    @MainActor
    public func errorBlock(_ block: @escaping ErrorBlock) -> ResourceRequest {
        errorBlock.append(block)
        return self
    }
    
    @MainActor
    public func progressBlock(_ block: @escaping ProgressBlock) -> ResourceRequest {
        progressBlock.append(block)
        return self
    }
}

extension ResourceRequest {
    
    func response(result: ResourceDownloadResult) {
        Task { @MainActor in
            successBlocks.forEach{ $0(result) }
        }
    }
    
    func response(error: ResourceTransferError) {
        Task { @MainActor in
            errorBlock.forEach{ $0(error) }
        }
    }
    
    func response(progress: Float) {
        Task { @MainActor in
            progressBlock.forEach{ $0(progress) }
        }
    }
}

// MARK: - 便捷式入口
extension ResourceRequest {
    
    public func startLoad() {
        ResourceScheduler.default.load(request: self, subscriber: DownloadResultSubscriber())
    }
    
    public func pause() {
        ResourceScheduler.default.pause(request: self)
    }

    public func cancel() {
        ResourceScheduler.default.cancel(request: self)
    }
}
