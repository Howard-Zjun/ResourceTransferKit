//
//  ResourceScheduler.swift
//  ResourceTransferKit
//
//  Created by Howard-Zjun on 2026/9/6.
//

import UIKit

private enum CacheLookupResult {
    case handled(CacheMetadata)
    case stale(CacheMetadata)
    case miss
}

private final class SubscriberContext {

    var subscribers: [DownloadResultSubscriber]

    init(subscriber: DownloadResultSubscriber) {
        subscribers = [subscriber]
    }
}

public final class ResourceScheduler: NSObject {

    private static let minimumResumableBytes: Int64 = 5 * 1024 * 1024
    
    // MARK: -------------- lock from
    /// 以资源键维护正在处理的下载上下文，用于请求去重与快速取消。
    private var downloadingContexts: [ResourceKey: DownloadContext] = [:]
    
    /// 等待队列
    private var waitingContexts: [ResourceKey: DownloadContext] = [:]

    /// 正在等待重试间隔结束的任务。
    private var retryingContexts: [ResourceKey: DownloadContext] = [:]
    
    private var subscribers: [ResourceKey : SubscriberContext] = [:]

    // MARK: -------------- lock end
    
    private let lock: NSLock = .init()

    private let configuration: URLSessionConfiguration

    private let cacheStore: CacheStore
    
    private lazy var downloader: ResourceDownloader = {
        let result = ResourceDownloader(configuration: self.configuration)
        return result
    }()
    
    public static let `default`: ResourceScheduler = .init()

    /// 实际下载并发上限，范围为 3...7，默认值为 5。
    /// 降低上限不会取消正在执行的下载。
    public var maxDownloadCount: Int {
        get {
            lock.lock()
            defer { lock.unlock() }
            return downloader.maxDownloadCount
        }
        set {
            lock.lock()
            downloader.maxDownloadCount = newValue
            lock.unlock()
            startWaitingContextsIfPossible()
        }
    }
    
    private override init() {
        configuration = .default
        cacheStore = .default
        super.init()
    }

    // MARK: - Unit Test
    #if DEBUG
    /// 仅供模块测试注入 URLProtocol 配置，不属于公开 API，Release 不编译此入口。
    internal init(configuration: URLSessionConfiguration) {
        self.configuration = configuration
        cacheStore = .default
        super.init()
    }
    #endif
}

// MARK: - 取消加载
extension ResourceScheduler {
    
    /// 外部加锁保证安全
    private func removeSubscriber(subscriber: DownloadResultSubscriber) -> DownloadContext? {
        let resource = subscriber.resource
        guard let context = downloadingContexts[resource.key]
                ?? waitingContexts[resource.key]
                ?? retryingContexts[resource.key] else {
            return nil
        }
        
        guard let subscriberContext = subscribers[resource.key],
              subscriberContext.subscribers.contains(where: { $0 === subscriber }) else {
            return nil
        }
        subscriberContext.subscribers.removeAll(where: { $0 === subscriber })
        
        return context
    }
    
    internal func cancel(subscriber: DownloadResultSubscriber) {
        subscriber.invalidateCallbacks()
        lock.lock()
        
        let resource = subscriber.resource
        guard let context = removeSubscriber(subscriber: subscriber),
              let subscriberContext = subscribers[resource.key] else {
            lock.unlock()
            return
        }
        
        if subscriberContext.subscribers.isEmpty {
            subscribers.removeValue(forKey: resource.key)
            waitingContexts.removeValue(forKey: resource.key)
            retryingContexts.removeValue(forKey: resource.key)
            let wasDownloading = downloadingContexts.removeValue(forKey: resource.key) != nil
            lock.unlock()
            if wasDownloading, (context.fileSize ?? 0) >= Self.minimumResumableBytes {
                context.cancelPreservingResumeData { _ in }
            } else {
                context.cancel()
            }
        } else {
            context.effectivePriority = subscriberContext.subscribers.map { $0.resource.priority }.max() ?? .normal
            lock.unlock()
        }
        startWaitingContextsIfPossible()
    }
}

// MARK: - 开启下载任务
extension ResourceScheduler {
    
    private func cacheHandle(resource: ResourceRequest) -> CacheLookupResult {
        guard resource.usesCacheIfAvailable,
              let cacheResult = cacheStore.load(key: resource.key) else {
            return .miss
        }
        guard cacheResult.isFresh else {
            return .stale(cacheResult)
        }
     
        return .handled(cacheResult)
    }
    
    private func responseFromCache(subscriber: DownloadResultSubscriber, cacheResult: CacheMetadata) {
        let result = ResourceDownloadResult(
            localURL: cacheResult.localURL,
            fileSize: cacheResult.fileSize,
            mimeType: cacheResult.mimeType
        )
        sendSuccess(to: [subscriber], result: result)
    }
    
    /// 加锁确认安全
    private func findMatchContext(resource: ResourceRequest) -> DownloadContext? {
        downloadingContexts[resource.key]
        ?? waitingContexts[resource.key]
        ?? retryingContexts[resource.key]
    }
    
    internal func load(subscriber: DownloadResultSubscriber) {
        guard subscriber.attach(to: self) else { return }
        let resource = subscriber.resource
        lock.lock()
        if let context = findMatchContext(resource: resource) {
            appendSubscriber(subscriber, to: context)
            lock.unlock()
            return
        }
        lock.unlock()

        switch cacheHandle(resource: resource) {
        case let .handled(metadata):
            responseFromCache(subscriber: subscriber, cacheResult: metadata)
            return
        case .miss, .stale:
            break
        }

        lock.lock()
        defer {
            lock.unlock()
            startWaitingContextsIfPossible()
        }

        if let context = findMatchContext(resource: resource) {
            appendSubscriber(subscriber, to: context)
        } else {
            // 创建新的下载任务
            let context = DownloadContext(resource: resource, scheduler: self)
            subscribers[resource.key] = SubscriberContext(subscriber: subscriber)
            waitingContexts[resource.key] = context
        }
    }

    /// 调用方持有 lock。
    private func appendSubscriber(_ subscriber: DownloadResultSubscriber, to context: DownloadContext) {
        guard let subscriberContext = subscribers[context.key],
              !subscriberContext.subscribers.contains(where: { $0.matches(subscriber) }) else {
            return
        }
        subscriberContext.subscribers.append(subscriber)
        context.effectivePriority = max(context.effectivePriority, subscriber.resource.priority)
    }
}

extension ResourceScheduler {
    
    private func startWaitingContextsIfPossible() {
        lock.lock()
        defer { lock.unlock() }
        
        func nextWaitingContext() -> DownloadContext? {
            waitingContexts.values.filter {
                guard let subscriberContext = subscribers[$0.key], !subscriberContext.subscribers.isEmpty else { return false }
                if case .waiting = $0.state { return true }
                return false
            }.max { lhs, rhs in
                if lhs.effectivePriority != rhs.effectivePriority {
                    return lhs.effectivePriority < rhs.effectivePriority
                }
                return lhs.creationTime > rhs.creationTime
            }
        }
        
        while downloadingContexts.count < downloader.maxDownloadCount, let context = nextWaitingContext() {
            waitingContexts.removeValue(forKey: context.key)
            downloadingContexts[context.key] = context
            downloader.addDownload(context: context)
        }
    }
    
}

extension ResourceScheduler {

    private func retryDelay(for failRetryCount: Int) -> TimeInterval {
        let exponent = min(max(failRetryCount - 1, 0), 3)
        return TimeInterval(1 << exponent)
    }
    
    private func enqueueRetry(context: DownloadContext) {
        lock.lock()
        guard retryingContexts[context.key] === context,
              let subscriberContext = subscribers[context.key],
              !subscriberContext.subscribers.isEmpty,
              context.prepareForRetry() else {
            lock.unlock()
            return
        }
        retryingContexts.removeValue(forKey: context.key)
        waitingContexts[context.key] = context
        lock.unlock()
        startWaitingContextsIfPossible()
    }
}

extension ResourceScheduler {
    
    internal func responseProgress(context: DownloadContext, progress: Float) {
        lock.lock()
        guard downloadingContexts[context.key] === context else {
            lock.unlock()
            return
        }
        let snapshot = subscribers[context.key]?.subscribers ?? []
        lock.unlock()
        
        snapshot.forEach { $0.response(progress: progress) }
    }
        
    internal func responseBySuccess(context: DownloadContext, result: ResourceDownloadResult) {
        lock.lock()
        guard downloadingContexts[context.key] === context else {
            lock.unlock()
            return
        }
        downloadingContexts.removeValue(forKey: context.key)
        let snapshot = subscribers.removeValue(forKey: context.key)?.subscribers ?? []
        lock.unlock()

        sendSuccess(to: snapshot, result: result)
        startWaitingContextsIfPossible()
    }

    private func sendSuccess(to subscribers: [DownloadResultSubscriber], result: ResourceDownloadResult) {
        let fileManager = FileManager.default
        var copies: [URL: Result<Void, Error>] = [:]
        for subscriber in subscribers {
            do {
                if let path = subscriber.resource.customSavePath,
                   path.standardizedFileURL != result.localURL.standardizedFileURL {
                    var isDirectory: ObjCBool = false
                    let exists = fileManager.fileExists(atPath: path.path, isDirectory: &isDirectory)
                    guard path.isFileURL, !path.hasDirectoryPath, !(exists && isDirectory.boolValue) else {
                        throw CocoaError(.fileWriteInvalidFileName)
                    }
                    let destination = path.standardizedFileURL
                    if let copy = copies[destination] {
                        try copy.get()
                    } else {
                        let copy = Result<Void, Error> {
                            try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                            if fileManager.fileExists(atPath: destination.path) {
                                try fileManager.removeItem(at: destination)
                            }
                            try fileManager.copyItem(at: result.localURL, to: destination)
                        }
                        copies[destination] = copy
                        try copy.get()
                    }
                }
                subscriber.response(result: result)
            } catch {
                subscriber.response(error: .underlying(error))
            }
        }
    }
    
    internal func responseByFail(context: DownloadContext, error: ResourceTransferError) {
        lock.lock()
        guard downloadingContexts[context.key] === context,
              let subscriberContext = subscribers[context.key] else {
            lock.unlock()
            return
        }
        downloadingContexts.removeValue(forKey: context.key)
        let failRetryCount = context.failRetryCount
        let failedSubscribers = subscriberContext.subscribers.filter {
            !error.isRetryable || failRetryCount > $0.resource.maxFailRetryCount
        }
        subscriberContext.subscribers.removeAll {
            !error.isRetryable || failRetryCount > $0.resource.maxFailRetryCount
        }
        let shouldRetry = !subscriberContext.subscribers.isEmpty
        let delay = retryDelay(for: failRetryCount)
        if shouldRetry {
            context.effectivePriority = subscriberContext.subscribers.map { $0.resource.priority }.max() ?? .normal
            retryingContexts[context.key] = context
        } else {
            subscribers.removeValue(forKey: context.key)
            context.finishFailure(error)
        }
        lock.unlock()

        failedSubscribers.forEach { $0.response(error: error) }
        if shouldRetry {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.enqueueRetry(context: context)
            }
        }
        startWaitingContextsIfPossible()
    }
}
