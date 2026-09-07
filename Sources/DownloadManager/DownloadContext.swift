//
//  DownloadContext.swift
//  ResourceTransferDemo
//
//  Created by Howard-Zjun on 2026/9/4.
//

import UIKit
import UniformTypeIdentifiers

// MARK: - 下载上下文
final class DownloadContext {
    
    let key: ResourceKey
    
    /// 模块资源保存路径
    var moduleSaveURL: URL
    
    var subscribers: [DownloadSubscriber]
    
    weak var operation: DownloadOperation?
    
    var effectivePriority: RequestPriority
    
    let creationTime: Date
    
    var startDownloadTime: Date?
    
    /// 当前资源任务已消耗的失败重试次数，所有订阅者共享。
    var failRetryCount: Int = 0
    
    var progress: Float?
    
    var mimeType: String? {
        didSet {
            guard oldValue == nil, let mimeType else {
                return
            }
            
            let resourceType = UTType(mimeType: mimeType)
            let filename = moduleSaveURL
                .deletingPathExtension()
                .lastPathComponent
            let directoryName = resourceType.map {
                Self.directoryName(for: $0, mimeType: mimeType)
            } ?? "Other"
            var updatedURL = Self.resourcesRootURL
                .appendingPathComponent(
                    directoryName,
                    isDirectory: true
                )
                .appendingPathComponent(filename)
            if let pathExtension = resourceType?.preferredFilenameExtension {
                updatedURL = updatedURL.appendingPathExtension(pathExtension)
            } else if !moduleSaveURL.pathExtension.isEmpty {
                updatedURL = updatedURL.appendingPathExtension(moduleSaveURL.pathExtension)
            }
            moduleSaveURL = updatedURL
        }
    }
    
    var fileSize: Int64?
    
    init(request: ResourceRequest, subscriber: DownloadResultSubscriber, priority: RequestPriority) {
        self.key = request.key
        self.moduleSaveURL = Self.defaultSavePath(for: request.url)
        self.subscribers = [.init(request: request, resultSubscriber: subscriber)]
        self.effectivePriority = priority
        creationTime = .init()
    }
    
}

extension DownloadContext {
    
    private static func defaultSavePath(for url: URL) -> URL {
        let identifier = url.absoluteString.addingPercentEncoding(
            withAllowedCharacters: .alphanumerics
        ) ?? UUID().uuidString
        let filename = url.pathExtension.isEmpty
            ? identifier
            : "\(identifier).\(url.pathExtension)"

        return resourcesRootURL
            .appendingPathComponent("Images", isDirectory: true)
            .appendingPathComponent(filename)
    }

    private static var resourcesRootURL: URL {
        let cachesDirectory = FileManager.default.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        )[0]
        return cachesDirectory
            .appendingPathComponent("ResourceTransferKit", isDirectory: true)
    }

    private static func directoryName(for type: UTType, mimeType: String) -> String {
        if type.conforms(to: .image) {
            return "Images"
        }
        if type.conforms(to: .audio) {
            return "Audio"
        }
        if type.conforms(to: .movie) {
            return "Videos"
        }
        if type.conforms(to: .pdf) {
            return "PDF"
        }
        if ["application/zip", "application/x-zip-compressed"].contains(mimeType.lowercased()) {
            return "ZIP"
        }
        return "Other"
    }
}

class DownloadSubscriber {
    
    let request: ResourceRequest
    
    let resultSubscriber: DownloadResultSubscriber
    
    init(request: ResourceRequest, resultSubscriber: DownloadResultSubscriber) {
        self.request = request
        self.resultSubscriber = resultSubscriber
    }
}
