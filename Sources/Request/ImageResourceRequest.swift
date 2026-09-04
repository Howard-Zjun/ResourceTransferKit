//
//  ImageResourceRequest.swift
//  ResourceTransferDemo
//
//  Created by Howard-Zjun on 2026/9/3.
//

import Foundation
import UIKit

struct ImageResourceRequest: ResourceRequest {
    
    var key: ResourceKey {
        .init(url: url)
    }
    
    let url: URL
    
    /// 下载完成后资源的最终本地位置。
    let savePath: URL
    
    let completion: ((URL) -> Void)?
    
    let errorBlock: ((ResourceTransferError) -> Void)?
    
    init(
        url: URL,
        completion: ((URL) -> Void)? = nil,
        errorBlock: ((ResourceTransferError) -> Void)? = nil
    ) {
        self.url = url
        self.savePath = Self.defaultSavePath(for: url)
        self.completion = completion
        self.errorBlock = errorBlock
    }
    
    private static func defaultSavePath(for url: URL) -> URL {
        let cachesDirectory = FileManager.default.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        )[0]
        let imagesDirectory = cachesDirectory
            .appendingPathComponent("ResourceTransferKit", isDirectory: true)
            .appendingPathComponent("Images", isDirectory: true)
        let identifier = url.absoluteString.addingPercentEncoding(
            withAllowedCharacters: .alphanumerics
        ) ?? UUID().uuidString
        let filename = url.pathExtension.isEmpty
            ? identifier
            : "\(identifier).\(url.pathExtension)"

        return imagesDirectory.appendingPathComponent(filename)
    }
}
