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

    /// 正在等待重试间隔结束的任务。
    private var retryingContexts: [ResourceKey: DownloadContext] = [:]
    
    private let lock: NSLock = .init()

    private let configuration: URLSessionConfiguration
    
    private lazy var downloader: ResourceDownloader = {
        let result = ResourceDownloader(configuration: self.configuration)
        result.schedulerDelegate = self
        return result
    }()
    
    public static let `default`: ResourceScheduler = .init()

    public var maxDownloadCount: Int {
        get {
            lock.lock()
            defer { lock.unlock() }
            return downloader.maxDownloadCount
        }
        set {
            lock.lock()
            let downloader = downloader
            lock.unlock()
            downloader.maxDownloadCount = newValue
        }
    }
    
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
    
    func cancel(request: ResourceRequest) {
        lock.lock()
        defer { lock.unlock() }
        
        if let context = downloadingContexts[request.key]
            ?? waitingContexts[request.key]
            ?? retryingContexts[request.key] {
            context.subscribers.removeAll { $0.request.identifier == request.identifier }
            if context.subscribers.isEmpty {
                waitingContexts.removeValue(forKey: request.key)
                downloadingContexts.removeValue(forKey: request.key)
                retryingContexts.removeValue(forKey: request.key)
                context.state = .cancelled
                context.operation?.cancel()
            } else {
                context.effectivePriority = context.subscribers.map { $0.request.initialPriority }.max() ?? .normal
            }
        }
        startWaitingContextsIfPossible()
    }
    
    func cancel(subscriber: DownloadResultSubscriber) {
        lock.lock()
        defer { lock.unlock() }
        
        removeSubscriber(subscriber, exceptFor: nil, from: &waitingContexts)
        removeSubscriber(subscriber, exceptFor: nil, from: &downloadingContexts)
        removeSubscriber(subscriber, exceptFor: nil, from: &retryingContexts)
        startWaitingContextsIfPossible()
    }
}

// TODO: 之后看下需不需要处理304缓存映射码
// TODO: 看下如何分段下载提高效率
// TODO: 看下如何断点续传提供性能
extension ResourceScheduler {
    
    func load(request: ResourceRequest, subscriber: DownloadResultSubscriber) {
        lock.lock()
        defer { lock.unlock() }

        // 1. 当前订阅者若已订阅其他资源，先解除旧订阅。
        removeSubscriber(subscriber, exceptFor: request.key, from: &waitingContexts)
        removeSubscriber(subscriber, exceptFor: request.key, from: &downloadingContexts)
        removeSubscriber(subscriber, exceptFor: request.key, from: &retryingContexts)

        // 2. 命中相同资源时，共用已有任务；等待中的任务还会提升到最高订阅优先级。
        if let context = downloadingContexts[request.key]
            ?? waitingContexts[request.key]
            ?? retryingContexts[request.key] {
            context.subscribers.append(
                DownloadSubscriber(request: request, resultSubscriber: subscriber)
            )
            context.effectivePriority = max(context.effectivePriority, request.initialPriority)
            return
        }

        // 3. 首次请求先进入等待队列；仅在有下载槽位时创建 operation。
        let context = DownloadContext(request: request, subscriber: subscriber, priority: request.initialPriority)
        waitingContexts[request.key] = context
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
            context.state = .downloading(progress: context.progress ?? 0)
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

    private func retryDelay(for failRetryCount: Int) -> TimeInterval {
        let exponent = min(max(failRetryCount - 1, 0), 3)
        return TimeInterval(1 << exponent)
    }

    private func enqueueRetry(key: ResourceKey, context: DownloadContext) {
        lock.lock()
        defer { lock.unlock() }

        guard let retryingContext = retryingContexts[key], retryingContext === context else {
            return
        }
        retryingContexts.removeValue(forKey: key)
        context.state = .waiting
        waitingContexts[key] = context
        startWaitingContextsIfPossible()
    }
    
    private func removeSubscriber(
        _ subscriber: DownloadResultSubscriber,
        exceptFor retainedKey: ResourceKey?,
        from contexts: inout [ResourceKey: DownloadContext]
    ) {
        let keysToRemove = contexts.compactMap { key, context -> ResourceKey? in
            guard key != retainedKey else {
                return nil
            }
            context.subscribers.removeAll { $0.resultSubscriber.matches(subscriber) }
            return context.subscribers.isEmpty ? key : nil
        }

        for key in keysToRemove {
            let context = contexts.removeValue(forKey: key)
            context?.state = .cancelled
            context?.operation?.cancel()
        }
    }
}

extension ResourceScheduler: ResourceDownloaderDelegate {
    
    func downloadProgress(key: ResourceKey, mimeType: String?, bytesWritten: Int64, expectedBytes: Int64) {
        lock.lock()
        guard let context = downloadingContexts[key] else {
            lock.unlock()
            return
        }
        if context.startDownloadTime == nil {
            context.startDownloadTime = .init()
        }
        if context.mimeType == nil {
            context.mimeType = mimeType
        }
        context.fileSize = bytesWritten
        guard expectedBytes > 0 else {
            lock.unlock()
            return
        }
        let progress = Float(bytesWritten) / Float(expectedBytes)
        context.progress = progress
        context.state = .downloading(progress: progress)
        let subscribers = context.subscribers
        lock.unlock()
        Task { @MainActor in
            subscribers.forEach { $0.request.progressBlock?(progress) }
        }
    }
    
    func downloadMaxQueueChange() {
        lock.lock()
        defer { lock.unlock() }
        
        startWaitingContextsIfPossible()
    }
    
    func downloadSuccess(key: ResourceKey, result: ResourceDownloadResult) {
        lock.lock()
        guard let context = downloadingContexts.removeValue(forKey: key) else {
            lock.unlock()
            return
        }
        context.state = .completed
        let subscribers = context.subscribers
        startWaitingContextsIfPossible()
        lock.unlock()

        var copies: [URL: Result<Void, Error>] = [:]
        var failedSubscribers: [(DownloadSubscriber, ResourceTransferError)] = []
        var completedSubscribers: [DownloadSubscriber] = []
        let fileManager = FileManager.default
        for subscriber in subscribers {
            do {
                if let path = subscriber.request.customSavePath,
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
                            try fileManager.createDirectory(
                                at: destination.deletingLastPathComponent(),
                                withIntermediateDirectories: true
                            )
                            if fileManager.fileExists(atPath: destination.path) {
                                try fileManager.removeItem(at: destination)
                            }
                            try fileManager.copyItem(at: result.localURL, to: destination)
                        }
                        copies[destination] = copy
                        try copy.get()
                    }
                }
            } catch {
                failedSubscribers.append((subscriber, .underlying(error)))
                continue
            }
            completedSubscribers.append(subscriber)
        }
        Task { @MainActor in
            failedSubscribers.forEach { $0.0.request.errorBlock?($0.1) }
            completedSubscribers.forEach { $0.request.completion?(result) }
        }
    }
    
    func downloadFail(key: ResourceKey, error: ResourceTransferError) {
        lock.lock()
        guard let context = downloadingContexts.removeValue(forKey: key) else {
            lock.unlock()
            return
        }

        context.failRetryCount += 1
        let failedSubscribers = context.subscribers.filter {
            !error.isRetryable || context.failRetryCount > $0.request.maxFailRetryCount
        }
        context.subscribers.removeAll {
            !error.isRetryable || context.failRetryCount > $0.request.maxFailRetryCount
        }
        if !context.subscribers.isEmpty {
            context.state = .retrying(failRetryCount: context.failRetryCount)
            retryingContexts[key] = context
            let retryDelay = retryDelay(for: context.failRetryCount)
            DispatchQueue.global().asyncAfter(deadline: .now() + retryDelay) { [weak self] in
                self?.enqueueRetry(key: key, context: context)
            }
        } else {
            context.state = .failed(error)
        }
        startWaitingContextsIfPossible()
        lock.unlock()

        Task { @MainActor in
            failedSubscribers.forEach { $0.request.errorBlock?(error) }
        }
    }
}
