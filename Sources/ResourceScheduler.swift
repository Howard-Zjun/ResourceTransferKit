//
//  ResourceScheduler.swift
//  ResourceTransferKit
//
//  Created by Howard-Zjun on 2026/9/6.
//

import UIKit

public final class ResourceScheduler: NSObject {
    
    /// 以资源键维护正在处理的下载上下文，用于请求去重与快速取消。
    private var downloadingContexts: [ResourceKey: DownloadContext] = [:]
    
    /// 等待队列
    private var waitingContexts: [ResourceKey: DownloadContext] = [:]
    
    private let lock: NSLock = .init()

    private let configuration: URLSessionConfiguration
    
    private lazy var downloader: ResourceDownloader = {
        let result = ResourceDownloader(configuration: self.configuration)
        result.schedulerDelegate = self
        return result
    }()
    
    public static let `default`: ResourceScheduler = .init()
    
    private override init() {
        configuration = .default
        super.init()
    }

    init(configuration: URLSessionConfiguration) {
        self.configuration = configuration
        super.init()
    }
}

extension ResourceScheduler {
    
    func cancel(key: ResourceKey) {
        lock.lock()
        defer { lock.unlock() }
        
        waitingContexts.removeValue(forKey: key)
        if let context = downloadingContexts.removeValue(forKey: key) {
            context.operation?.cancel()
        }
        startWaitingContextsIfPossible()
    }
    
    func cancel(imageView: UIImageView) {
        lock.lock()
        defer { lock.unlock() }
        
        removeSubscriber(imageView, exceptFor: nil, from: &waitingContexts)
        removeSubscriber(imageView, exceptFor: nil, from: &downloadingContexts)
        startWaitingContextsIfPossible()
    }
}

// TODO: 之后看下需不需要处理304缓存映射码
// TODO: 看下如何分段下载提高效率
// TODO: 看下如何断点续传提供性能
extension ResourceScheduler {
    
    func load(imageRequest: ResourceRequest, imageView: UIImageView? = nil) {
        lock.lock()
        defer { lock.unlock() }

        // 1. 当前视图若已订阅其他资源，先解除旧订阅。
        if let imageView {
            removeSubscriber(imageView, exceptFor: imageRequest.key, from: &waitingContexts)
            removeSubscriber(imageView, exceptFor: imageRequest.key, from: &downloadingContexts)
        }

        // 2. 命中相同资源时，共用已有任务；等待中的任务还会提升到最高订阅优先级。
        if let context = downloadingContexts[imageRequest.key] ?? waitingContexts[imageRequest.key] {
            context.subscribers.append(
                DownloadSubscriber(request: imageRequest, subscriberImageView: imageView)
            )
            context.effectivePriority = max(context.effectivePriority, imageRequest.initialPriority)
            return
        }

        // 3. 首次请求先进入等待队列；仅在有下载槽位时创建 operation。
        guard let imageView else {
            return
        }
        let context = DownloadContext(request: imageRequest, imgV: imageView, priority: imageRequest.initialPriority)
        waitingContexts[imageRequest.key] = context
        startWaitingContextsIfPossible()
    }
}

extension ResourceScheduler {
    
    /// 调用方必须持有 lock；按优先级降序、创建时间升序填充所有可用下载槽位。
    private func startWaitingContextsIfPossible() {
        while downloadingContexts.count < downloader.maxDownloadCount,
              let context = nextWaitingContext() {
            waitingContexts.removeValue(forKey: context.key)
            downloadingContexts[context.key] = context
            downloader.addDownload(context: context)
        }
    }
    
    private func nextWaitingContext() -> DownloadContext? {
        waitingContexts.values.max { lhs, rhs in
            if lhs.effectivePriority != rhs.effectivePriority {
                return lhs.effectivePriority < rhs.effectivePriority
            }
            return lhs.creationTime > rhs.creationTime
        }
    }
    
    private func removeSubscriber(
        _ imageView: UIImageView,
        exceptFor retainedKey: ResourceKey?,
        from contexts: inout [ResourceKey: DownloadContext]
    ) {
        let keysToRemove = contexts.compactMap { key, context -> ResourceKey? in
            guard key != retainedKey else {
                return nil
            }
            context.subscribers.removeAll { $0.subscriberImageView === imageView }
            return context.subscribers.isEmpty ? key : nil
        }

        for key in keysToRemove {
            let context = contexts.removeValue(forKey: key)
            context?.operation?.cancel()
        }
    }
}

extension ResourceScheduler: ResourceDownloaderDelegate {
    
    func contextFromDownloading(key: ResourceKey) -> DownloadContext? {
        lock.lock()
        defer { lock.unlock() }
        
        return downloadingContexts[key]
    }
    
    func downloadMaxQueueChange() {
        lock.lock()
        defer { lock.unlock() }
        
        startWaitingContextsIfPossible()
    }
    
    func downloadSuccess(key: ResourceKey, result: ResourceDownloadResult) {
        lock.lock()
        let subscribers = downloadingContexts.removeValue(forKey: key)?.subscribers ?? []
        startWaitingContextsIfPossible()
        lock.unlock()

        subscribers.forEach { subscriber in
            subscriber.request.completion?(result)
        }
    }
    
    func downloadFail(key: ResourceKey, error: ResourceTransferError) {
        lock.lock()
        let subscribers = downloadingContexts.removeValue(forKey: key)?.subscribers ?? []
        startWaitingContextsIfPossible()
        lock.unlock()

        subscribers.forEach { subscriber in
            subscriber.request.errorBlock?(error)
        }
    }
}
