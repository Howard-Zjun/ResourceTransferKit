//
//  ResourceDownloadResult.swift
//  ResourceTransferKit
//
//  Created by Howard-Zjun on 2026/9/6.
//

import UIKit

public struct ResourceDownloadResult {
    
    public let localURL: URL
    
    public let fileSize: Int64?
    
    public let mimeType: String?
    
    public var expectedType: ResourceType? {
        switch mimeType {
            case let value where value?.hasPrefix("image/") == true: .image
            case let value where value?.hasPrefix("audio/") == true: .audio
            case let value where value?.hasPrefix("video/") == true: .video
            case "application/pdf": .pdf
            case "application/zip", "application/x-zip-compressed": .zip
            default: .other
            }
    }
}

public enum ResourceType {
    case image
    case audio
    case video
    case pdf
    case zip
    case other
}
