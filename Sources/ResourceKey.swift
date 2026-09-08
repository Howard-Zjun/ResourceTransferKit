//
//  ResourceKey.swift
//  ResourceTransferDemo
//
//  Created by Howard-Zjun on 2026/9/4.
//

import UIKit

public struct ResourceKey: Hashable, Codable {
    
    let url: URL

    public static func == (lhs: ResourceKey, rhs: ResourceKey) -> Bool {
        lhs.url.absoluteString == rhs.url.absoluteString
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(url.absoluteString)
    }
}
