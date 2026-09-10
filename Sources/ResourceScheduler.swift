//
//  ResourceScheduler.swift
//  ResourceTransferKit
//
//  Created by Howard-Zjun on 2026/9/6.
//

import UIKit

public final class ResourceScheduler: NSObject {

    private static let minimumResumableBytes: Int64 = 5 * 1024 * 1024
    
    // MARK: -------------- lock from
    /// 以资源键维护正在处理的下载上下文，用于请求去重与快速取消。
    private var downloadingContexts: [ResourceKey: DownloadContext] = [:]
    
    /// 等待队列
    private var waitingContexts: [ResourceKey: DownloadContext] = [:]

    /// 正在等待重试间隔结束的任务。
    private var retryingContexts: [ResourceKey: DownloadContext] = [:]
    
    // MARK: -------------- lock end
    private let lock: NSLock = .init()

    private let configuration: URLSessionConfiguration

    private let cacheStore: CacheStore
    
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
        cacheStore = .default
        super.init()
    }

    // MARK: - Unit Test
    #if DEBUG
    /// 仅供测试注入 URLProtocol 配置，Release 环境只允许使用 ResourceScheduler.default。
    init(configuration: URLSessionConfiguration) {
        self.configuration = configuration
        cacheStore = .default
        super.init()
    }
    #endif
}

// MARK: - 暂停/取消下载
extension ResourceScheduler {
    
    func pause(request: ResourceRequest) {
        func removeRequestSubscriber(_ request: ResourceRequest, from context: DownloadContext) -> Bool {
            let subscriberCount = context.subscribers.count
            context.subscribers.removeAll { $0.request.identifier == request.identifier }
            return subscriberCount != context.subscribers.count
        }
        
        lock.lock()

        guard let context = downloadingContexts[request.key]
            ?? waitingContexts[request.key]
            ?? retryingContexts[request.key],
              removeRequestSubscriber(request, from: context) else {
            lock.unlock()
            return
        }
        if context.subscribers.isEmpty {
            waitingContexts.removeValue(forKey: request.key)
            retryingContexts.removeValue(forKey: request.key)
            guard downloadingContexts.removeValue(forKey: request.key) != nil, (context.fileSize ?? 0) >= Self.minimumResumableBytes else {
                context.cancel()
                startWaitingContextsIfPossible()
                lock.unlock()
                return
            }
            downloadingContexts[request.key] = context
            context.updateState(.pausing)
            lock.unlock()
            context.cancelPreservingResumeData { [weak self, weak context] canResume in
                guard let self, let context else { return }
                self.lock.lock()
                guard self.downloadingContexts[context.key] === context else {
                    self.lock.unlock()
                    return
                }
                self.downloadingContexts.removeValue(forKey: context.key)
                if canResume {
                    context.updateState(.paused)
                    // TODO: 为无订阅者的暂停任务增加容量或 TTL 回收策略。
                    self.waitingContexts[context.key] = context
                }
                self.startWaitingContextsIfPossible()
                lock.unlock()
            }
            lock.lock()
        } else {
            context.effectivePriority = context.subscribers.map { $0.request.initialPriority }.max() ?? .normal
        }
        
        startWaitingContextsIfPossible()
        lock.unlock()
    }
    
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
                context.cancel()
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

extension ResourceScheduler {
    
    private func cacheHandle(request: ResourceRequest, subscriber: DownloadResultSubscriber) -> Bool {
        guard let cacheResult = cacheStore.load(request: request) else {
            return false
        }

        let result = ResourceDownloadResult(
            localURL: cacheResult.localURL,
            fileSize: cacheResult.fileSize,
            mimeType: cacheResult.mimeType
        )
        if let path = request.customSavePath,
           path.standardizedFileURL != result.localURL.standardizedFileURL {
            do {
                var isDirectory: ObjCBool = false
                let exists = FileManager.default.fileExists(
                    atPath: path.path,
                    isDirectory: &isDirectory
                )
                guard path.isFileURL, !path.hasDirectoryPath,
                      !(exists && isDirectory.boolValue) else {
                    throw CocoaError(.fileWriteInvalidFileName)
                }
                let destination = path.standardizedFileURL
                try FileManager.default.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.copyItem(at: result.localURL, to: destination)
            } catch {
                lock.lock()
                removeSubscriber(subscriber, exceptFor: nil, from: &waitingContexts)
                removeSubscriber(subscriber, exceptFor: nil, from: &downloadingContexts)
                removeSubscriber(subscriber, exceptFor: nil, from: &retryingContexts)
                startWaitingContextsIfPossible()
                lock.unlock()
                Task { @MainActor in
                    request.errorBlock?(.underlying(error))
                }
                return true
            }
        }
        lock.lock()
        removeSubscriber(subscriber, exceptFor: nil, from: &waitingContexts)
        removeSubscriber(subscriber, exceptFor: nil, from: &downloadingContexts)
        removeSubscriber(subscriber, exceptFor: nil, from: &retryingContexts)
        startWaitingContextsIfPossible()
        lock.unlock()
        Task { @MainActor in
            request.completion?(result)
        }
        return true
    }
    
    func load(request: ResourceRequest, subscriber: DownloadResultSubscriber) {
        if cacheHandle(request: request, subscriber: subscriber) {
            return
        }

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
            if case .pausing = context.state {
                Task { @MainActor in
                    request.errorBlock?(.pausingInProgress)
                }
                return
            }
            context.subscribers.append(
                DownloadSubscriber(request: request, resultSubscriber: subscriber)
            )
            context.effectivePriority = max(context.effectivePriority, request.initialPriority)
            if case .paused = context.state {
                context.updateState(.waiting)
            }
            startWaitingContextsIfPossible()
            return
        }

        // 3. 首次请求先进入等待队列；仅在有下载槽位时创建 operation。
        let context = DownloadContext(
            request: request,
            subscriber: subscriber,
            priority: request.initialPriority
        )
        waitingContexts[request.key] = context
        startWaitingContextsIfPossible()
    }
}

// MARK: - 调度，需要lock包裹
extension ResourceScheduler {
    
    /// 调用方必须持有 lock；按优先级降序、创建时间升序填充所有可用下载槽位。
    private func startWaitingContextsIfPossible() {
        while downloadingContexts.count < downloader.maxDownloadCount,
              let context = nextWaitingContext() {
            waitingContexts.removeValue(forKey: context.key)
            downloadingContexts[context.key] = context
            context.updateState(.downloading(progress: context.progress ?? 0))
            downloader.addDownload(context: context)
        }
    }
    
    private func nextWaitingContext() -> DownloadContext? {
        waitingContexts.values.filter {
            guard !$0.subscribers.isEmpty else { return false }
            if case .waiting = $0.state { return true }
            return false
        }.max { lhs, rhs in
            if lhs.effectivePriority != rhs.effectivePriority {
                return lhs.effectivePriority < rhs.effectivePriority
            }
            return lhs.creationTime > rhs.creationTime
        }
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
            let subscriberCount = context.subscribers.count
            context.subscribers.removeAll { $0.resultSubscriber.matches(subscriber) }
            return subscriberCount != context.subscribers.count && context.subscribers.isEmpty ? key : nil
        }

        for key in keysToRemove {
            let context = contexts.removeValue(forKey: key)
            context?.cancel()
        }
    }
}

extension ResourceScheduler {

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
        context.updateState(.waiting)
        waitingContexts[key] = context
        startWaitingContextsIfPossible()
    }
}

extension ResourceScheduler: ResourceDownloaderDelegate {
    
    func downloadProgress(key: ResourceKey, mimeType: String?, bytesWritten: Int64, expectedBytes: Int64) {
        lock.lock()
        guard let context = downloadingContexts[key] else {
            lock.unlock()
            return
        }
        guard case .downloading = context.state else {
            lock.unlock()
            return
        }
        if context.startDownloadTime == nil {
            context.startDownloadTime = .init()
        }
        context.updateDownloadMetadata(mimeType: mimeType, fileSize: bytesWritten)
        guard expectedBytes > 0 else {
            lock.unlock()
            return
        }
        let progress = Float(bytesWritten) / Float(expectedBytes)
        context.progress = progress
        context.updateState(.downloading(progress: progress))
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
        context.updateState(.completed)
        let subscribers = context.subscribers
        startWaitingContextsIfPossible()
        lock.unlock()

        let cachedResult = (try? cacheStore.save(
            key: key,
            downloadResult: result
        )) ?? result

        var copies: [URL: Result<Void, Error>] = [:]
        var failedSubscribers: [(DownloadSubscriber, ResourceTransferError)] = []
        var completedSubscribers: [DownloadSubscriber] = []
        let fileManager = FileManager.default
        for subscriber in subscribers {
            do {
                if let path = subscriber.request.customSavePath,
                   path.standardizedFileURL != cachedResult.localURL.standardizedFileURL {
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
                            try fileManager.copyItem(at: cachedResult.localURL, to: destination)
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
            completedSubscribers.forEach { $0.request.completion?(cachedResult) }
        }
    }
    
    func downloadFail(key: ResourceKey, error: ResourceTransferError) {
        lock.lock()
        defer { lock.unlock() }
        
        guard let context = downloadingContexts.removeValue(forKey: key) else {
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
            context.updateState(.retrying(failRetryCount: context.failRetryCount))
            retryingContexts[key] = context
            let retryDelay = retryDelay(for: context.failRetryCount)
            DispatchQueue.global().asyncAfter(deadline: .now() + retryDelay) { [weak self] in
                self?.enqueueRetry(key: key, context: context)
            }
        } else {
            context.updateState(.failed(error))
        }
        startWaitingContextsIfPossible()

        Task { @MainActor in
            failedSubscribers.forEach { $0.request.errorBlock?(error) }
        }
    }
}
