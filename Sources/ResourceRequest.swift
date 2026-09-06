//
//  ResourceRequest.swift
//  ResourceTransferDemo
//
//  Created by Howard-Zjun on 2026/9/4.
//

import UIKit

// MARK: - 请求参数封装
struct ResourceRequest {
    
    var key: ResourceKey {
        .init(url: url)
    }
    
    let url: URL
    
    let initialPriority: RequestPriority
    
    let completion: ((ResourceDownloadResult) -> Void)?
    
    let errorBlock: ((ResourceTransferError) -> Void)?
    
    let progressBlock: ((Float) -> Void)?
    
    init(
        url: URL,
        priority: RequestPriority = .normal,
        completion: ((ResourceDownloadResult) -> Void)? = nil,
        errorBlock: ((ResourceTransferError) -> Void)? = nil,
        progressBlock: ((Float) -> Void)? = nil
    ) {
        self.url = url
        self.initialPriority = priority
        self.completion = completion
        self.errorBlock = errorBlock
        self.progressBlock = progressBlock
    }
}
