//
//  ResourceKey.swift
//  ResourceTransferDemo
//
//  Created by Howard-Zjun on 2026/9/4.
//

import UIKit

struct ResourceKey: Hashable {
    
    let url: URL

    static func == (lhs: ResourceKey, rhs: ResourceKey) -> Bool {
        lhs.url.path == rhs.url.path
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(url.path)
    }
}
