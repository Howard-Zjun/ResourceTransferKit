//
//  ResourceDownloader.swift
//  ResourceTransferDemo
//
//  Created by Howard-Zjun on 2026/9/3.
//

import Foundation
import UIKit

protocol ResourceDownloaderDelegate: NSObjectProtocol {
    
    func contextFromDownloading(key: ResourceKey) -> DownloadContext?
    
    func downloadMaxQueueChange()
    
    func downloadSuccess(key: ResourceKey, result: ResourceDownloadResult)
    
    func downloadFail(key: ResourceKey, error: ResourceTransferError)
}

public final class ResourceDownloader: NSObject {

    var maxDownloadRange: (Int, Int) = (3, 7)

    private var session: URLSession!
    
    weak var schedulerDelegate: ResourceDownloaderDelegate?
    
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
            schedulerDelegate?.downloadMaxQueueChange()
        }
        get {
            downloadQueue.maxConcurrentOperationCount
        }
    }
    
    // 多线程管理
    private let downloadQueue: OperationQueue = .init()
    
    public static let `default`: ResourceDownloader = .init()
    
    private override init() {
        super.init()
        session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        configInit()
    }

    /// 仅供模块内部和测试注入自定义网络配置。
    init(configuration: URLSessionConfiguration) {
        super.init()
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        configInit()
    }
    
    private func configInit() {
        maxDownloadCount = (maxDownloadRange.0 + maxDownloadRange.1) / 2
    }
}

extension ResourceDownloader {
    
    func addDownload(context: DownloadContext) {
        let operation = DownloadOperation(context: context, session: session, downloader: self)
        downloadQueue.addOperation(operation)
    }
}

extension ResourceDownloader {
    
    func downloadSuccess(key: ResourceKey, result: ResourceDownloadResult) {
        schedulerDelegate?.downloadSuccess(key: key, result: result)
    }
    
    func downloadFail(key: ResourceKey, error: ResourceTransferError) {
        schedulerDelegate?.downloadFail(key: key, error: error)
    }
}

extension ResourceDownloader: URLSessionDownloadDelegate {
    
    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
    }

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let url = downloadTask.originalRequest?.url,
              let context = schedulerDelegate?.contextFromDownloading(key: .init(url: url)) else {
            return
        }

        if context.mimeType == nil {
            context.mimeType = downloadTask.response?.mimeType
        }
        context.fileSize = totalBytesWritten
        if totalBytesExpectedToWrite > 0 {
            context.progress = Float(totalBytesWritten) / Float(totalBytesExpectedToWrite)
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
