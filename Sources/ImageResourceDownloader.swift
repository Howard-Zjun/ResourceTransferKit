//
//  ImageResourceDownloader.swift
//  ResourceTransferDemo
//
//  Created by Howard-Zjun on 2026/9/3.
//

import Foundation
import UIKit

public final class ImageResourceDownloader: NSObject {

    var maxDownloadRange: (Int, Int) = (3, 7)

    let session: URLSession
    
    /// 以资源键维护正在处理的下载上下文，用于请求去重与快速取消。
    var contexts: [ResourceKey: DownloadContext] = [:]
    
    let lock: NSLock = .init()
    
    public var maxDownloadCount: Int {
        set {
            if newValue > maxDownloadRange.1 {
                downloadQueue.maxConcurrentOperationCount = maxDownloadRange.1
            } else if newValue < maxDownloadRange.0 {
                downloadQueue.maxConcurrentOperationCount = maxDownloadRange.0
            } else {
                downloadQueue.maxConcurrentOperationCount = newValue
            }
        }
        get {
            downloadQueue.maxConcurrentOperationCount
        }
    }
    
    // 多线程管理
    private let downloadQueue: OperationQueue = .init()
    
    public static let `default`: ImageResourceDownloader = .init()
    
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
extension ImageResourceDownloader {

    func load(url: URL, imageView: UIImageView? = nil, completion: @escaping (URL) -> Void, errorBlock: @escaping (ResourceTransferError) -> Void) {
        load(
            imageRequest: .init(url: url, completion: completion, errorBlock: errorBlock),
            imageView: imageView
        )
    }

    func load(imageRequest: ImageResourceRequest, imageView: UIImageView? = nil) {
        lock.lock()
        defer { lock.unlock() }

        // 1. 当前视图若已订阅其他资源，先解除旧订阅。
        if let imageView {
            let contextsToCancel = contexts.compactMap { key, context -> ResourceKey? in
                guard key != imageRequest.key else {
                    return nil
                }
                context.subscribers.removeAll { subscriber in
                    subscriber.subscriberImageView === imageView
                }
                return context.subscribers.isEmpty ? key : nil
            }

            contextsToCancel.forEach { key in
                guard let context = contexts.removeValue(forKey: key) else {
                    return
                }
                context.operation?.cancel()
            }
        }

        // 2. 命中相同资源时，共用已有下载 operation，只追加订阅者。
        if let context = contexts[imageRequest.key] {
            if let imageView {
                let hasSubscribed = context.subscribers.contains { subscriber in
                    subscriber.subscriberImageView === imageView
                }
                if !hasSubscribed {
                    context.subscribers.append(
                        DownloadSubscriber(request: imageRequest, subscriberImageView: imageView)
                    )
                }
            }
            return
        }

        // 3. 首次请求该资源，创建 Context 和 operation 并加入调度队列。
        guard let imageView else {
            return
        }
        let context = DownloadContext(request: imageRequest, imgV: imageView)
        let operation = DownloadOperation(context: context, session: session, downloader: self)
        contexts[imageRequest.key] = context
        downloadQueue.addOperation(operation)
    }

    func cancel(key: ResourceKey) {
        lock.lock()
        if let context = contexts.removeValue(forKey: key) {
            context.operation?.cancel()
        }
        lock.unlock()
    }
    
    func cancel(imageView: UIImageView) {
        lock.lock()
        var keysToRemove: [ResourceKey] = []
        contexts.forEach { key, context in
            context.subscribers.removeAll { group in
                group.subscriberImageView === imageView
            }
            if context.subscribers.isEmpty {
                context.operation?.cancel()
                keysToRemove.append(key)
            }
        }
        keysToRemove.forEach { key in
            contexts.removeValue(forKey: key)
        }
        lock.unlock()
    }
    
    func successEnd(key: ResourceKey, localURL: URL) {
        lock.lock()
        let subscribers = contexts.removeValue(forKey: key)?.subscribers ?? []
        lock.unlock()

        subscribers.forEach { subscriber in
            subscriber.request.completion?(localURL)
        }
    }

    func errorEnd(key: ResourceKey, error: ResourceTransferError) {
        lock.lock()
        let subscribers = contexts.removeValue(forKey: key)?.subscribers ?? []
        lock.unlock()

        subscribers.forEach { subscriber in
            subscriber.request.errorBlock?(error)
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
