//
//  ResourceDownloader.swift
//  ResourceTransferDemo
//
//  Created by Howard-Zjun on 2026/9/3.
//

import Foundation
import UIKit

public final class ResourceDownloader: NSObject {

    var maxDownloadRange: (Int, Int) = (3, 7)

    let session: URLSession
    
    /// 以资源键维护正在处理的下载上下文，用于请求去重与快速取消。
    var downloadingContexts: [ResourceKey: DownloadContext] = [:]
    
    /// 等待队列
    var waitingContexts: [ResourceKey: DownloadContext] = [:]
    
    let lock: NSLock = .init()
    
    public var maxDownloadCount: Int {
        set {
            let count: Int
            if newValue > maxDownloadRange.1 {
                count = maxDownloadRange.1
            } else if newValue < maxDownloadRange.0 {
                count = maxDownloadRange.0
            } else {
                count = newValue
            }
            downloadQueue.maxConcurrentOperationCount = count
            scheduleWaitingContexts()
        }
        get {
            downloadQueue.maxConcurrentOperationCount
        }
    }
    
    // 多线程管理
    private let downloadQueue: OperationQueue = .init()
    
    public static let `default`: ResourceDownloader = .init()
    
    private override init() {
        self.session = .shared
        super.init()
        configInit()
    }

    /// 仅供模块内部和测试注入自定义网络会话。
    init(session: URLSession) {
        self.session = session
        super.init()
        configInit()
    }
    
    private func configInit() {
        maxDownloadCount = (maxDownloadRange.0 + maxDownloadRange.1) / 2
    }
}

// TODO: 之后看下需不需要处理304缓存映射码
// TODO: 看下如何分段下载提高效率
// TODO: 看下如何断点续传提供性能

// MARK: - 图片加载入口
extension ResourceDownloader {
    
    func load(url: URL, imageView: UIImageView? = nil, completion: @escaping (URL) -> Void, errorBlock: @escaping (ResourceTransferError) -> Void) {
        load(
            imageRequest: .init(url: url, priority: imageView != nil ? .high : .low, completion: completion, errorBlock: errorBlock),
            imageView: imageView
        )
    }

    func load(imageRequest: ImageResourceRequest, imageView: UIImageView? = nil) {
        lock.lock()
        defer { lock.unlock() }

        // 1. 当前视图若已订阅其他资源，先解除旧订阅。
        if let imageView {
            removeSubscriber(imageView, exceptFor: imageRequest.key, from: &waitingContexts)
            removeSubscriber(imageView, exceptFor: imageRequest.key, from: &downloadingContexts)
        }

        // 2. 命中相同资源时，共用已有任务；等待中的任务还会提升到最高订阅优先级。
        if let context = downloadingContexts[imageRequest.key] ?? waitingContexts[imageRequest.key] {
            appendSubscriber(
                imageRequest,
                imageView: imageView,
                to: context
            )
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

// MARK: - 取消加载入口
extension ResourceDownloader {
    
    func cancel(key: ResourceKey) {
        lock.lock()
        waitingContexts.removeValue(forKey: key)
        if let context = downloadingContexts.removeValue(forKey: key) {
            context.operation?.cancel()
        }
        startWaitingContextsIfPossible()
        lock.unlock()
    }
    
    func cancel(imageView: UIImageView) {
        lock.lock()
        removeSubscriber(imageView, exceptFor: nil, from: &waitingContexts)
        removeSubscriber(imageView, exceptFor: nil, from: &downloadingContexts)
        startWaitingContextsIfPossible()
        lock.unlock()
    }
}

// MARK: - 任务下载结果回调
extension ResourceDownloader {

    func successEnd(key: ResourceKey, localURL: URL) {
        lock.lock()
        let subscribers = downloadingContexts.removeValue(forKey: key)?.subscribers ?? []
        startWaitingContextsIfPossible()
        lock.unlock()

        subscribers.forEach { subscriber in
            subscriber.request.completion?(localURL)
        }
    }

    func errorEnd(key: ResourceKey, error: ResourceTransferError) {
        lock.lock()
        let subscribers = downloadingContexts.removeValue(forKey: key)?.subscribers ?? []
        startWaitingContextsIfPossible()
        lock.unlock()

        subscribers.forEach { subscriber in
            subscriber.request.errorBlock?(error)
        }
    }
}

// MARK: - 加入队列下载入口
extension ResourceDownloader {
    
    private func scheduleWaitingContexts() {
        lock.lock()
        startWaitingContextsIfPossible()
        lock.unlock()
    }
    
    /// 调用方必须持有 lock；按优先级降序、创建时间升序填充所有可用下载槽位。
    private func startWaitingContextsIfPossible() {
        while downloadingContexts.count < maxDownloadCount,
              let context = nextWaitingContext() {
            waitingContexts.removeValue(forKey: context.key)
            let operation = DownloadOperation(context: context, session: session, downloader: self)
            downloadingContexts[context.key] = context
            downloadQueue.addOperation(operation)
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
    
    private func appendSubscriber(
        _ request: ImageResourceRequest,
        imageView: UIImageView?,
        to context: DownloadContext
    ) {
        guard let imageView else {
            return
        }
        let hasSubscribed = context.subscribers.contains {
            $0.subscriberImageView === imageView
        }
        guard !hasSubscribed else {
            return
        }
        context.subscribers.append(
            DownloadSubscriber(request: request, subscriberImageView: imageView)
        )
        context.effectivePriority = max(context.effectivePriority, request.initialPriority)
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

public enum ResourceTransferError: Error, LocalizedError {
    case invalidURL(String)
    case network(URLError)
    case invalidResponse
    case unacceptableStatusCode(Int)
    case missingDownloadedFile
    case underlying(Error)

    public var errorDescription: String? {
        switch self {
        case let .invalidURL(url):
            return "无效的 HTTP(S) 地址：\(url)"
        case let .network(error):
            return "网络请求失败：\(error.localizedDescription)"
        case .invalidResponse:
            return "服务器返回了无效响应。"
        case let .unacceptableStatusCode(code):
            return "服务器返回了 HTTP 状态码 \(code)。"
        case .missingDownloadedFile:
            return "下载完成后未获得本地文件。"
        case let .underlying(error):
            return "资源传输失败：\(error.localizedDescription)"
        }
    }
}
