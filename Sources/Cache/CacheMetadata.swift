//
//  CacheMetadata.swift
//  ResourceTransferKit
//
//  Created by Howard-Zjun on 2026/9/11.
//

import Foundation

struct CacheMetadata: Codable {

    let resourceKey: ResourceKey
    
    let mimeType: String?
    
    let fileSize: Int64?

    var lastAccessDate: Date

    // MARK: - 强缓存
    let cacheControl: String?

    let responseDate: Date?

    let responseAge: TimeInterval?

    let expires: Date?

    let storedAt: Date

    var localURL: URL {
        CacheStore.default.cacheFileURL(for: resourceKey)
    }

    #if DEBUG
    func localURL(in cacheStore: CacheStore) -> URL {
        cacheStore.cacheFileURL(for: resourceKey)
    }
    #endif

    init(
        resourceKey: ResourceKey,
        mimeType: String?,
        fileSize: Int64?,
        lastAccessDate: Date,
        response: HTTPURLResponse? = nil
    ) {
        self.resourceKey = resourceKey
        self.mimeType = mimeType
        self.fileSize = fileSize
        self.lastAccessDate = lastAccessDate
        cacheControl = response?.value(forHTTPHeaderField: "Cache-Control")
        responseDate = response?.value(forHTTPHeaderField: "Date").flatMap(Self.httpDate)
        responseAge = response?.value(forHTTPHeaderField: "Age").flatMap(TimeInterval.init)
        expires = response?.value(forHTTPHeaderField: "Expires").flatMap(Self.httpDate)
        storedAt = .init()
    }

    private enum CodingKeys: String, CodingKey {
        case resourceKey
        case mimeType
        case fileSize
        case lastAccessDate
        case cacheControl
        case responseDate
        case responseAge
        case expires
        case storedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        resourceKey = try container.decode(ResourceKey.self, forKey: .resourceKey)
        mimeType = try container.decodeIfPresent(String.self, forKey: .mimeType)
        fileSize = try container.decodeIfPresent(Int64.self, forKey: .fileSize)
        lastAccessDate = try container.decodeIfPresent(Date.self, forKey: .lastAccessDate) ?? .init()
        cacheControl = try container.decodeIfPresent(String.self, forKey: .cacheControl)
        responseDate = try container.decodeIfPresent(Date.self, forKey: .responseDate)
        responseAge = try container.decodeIfPresent(TimeInterval.self, forKey: .responseAge)
        expires = try container.decodeIfPresent(Date.self, forKey: .expires)
        storedAt = try container.decodeIfPresent(Date.self, forKey: .storedAt) ?? lastAccessDate
    }
}

extension CacheMetadata {

    static func isStorable(response: HTTPURLResponse) -> Bool {
        cacheControlDirectives(from: response.value(forHTTPHeaderField: "Cache-Control"))["no-store"] == nil
    }

    var isFresh: Bool {
        guard isStorable else {
            return false
        }
        let directives = cacheControlDirectives
        if directives["no-cache"] != nil {
            return false
        }
        if let maxAge = directives["max-age"].flatMap(TimeInterval.init) {
            return currentAge < maxAge
        }
        if let expires {
            return Date() < expires
        }
        return false
    }

    var isStorable: Bool {
        cacheControlDirectives["no-store"] == nil
    }

    private var currentAge: TimeInterval {
        let dateValue = responseDate ?? storedAt
        let apparentAge = max(0, storedAt.timeIntervalSince(dateValue))
        return max(apparentAge, responseAge ?? 0) + Date().timeIntervalSince(storedAt)
    }

    private var cacheControlDirectives: [String: String] {
        Self.cacheControlDirectives(from: cacheControl)
    }

    private static func cacheControlDirectives(from cacheControl: String?) -> [String: String] {
        guard let cacheControl else {
            return [:]
        }
        return cacheControl.split(separator: ",").reduce(into: [:]) { directives, rawDirective in
            let pair = rawDirective.trimmingCharacters(in: .whitespaces).split(
                separator: "=",
                maxSplits: 1,
                omittingEmptySubsequences: false
            )
            guard let name = pair.first?.lowercased(), !name.isEmpty else {
                return
            }
            let value = pair.count == 2
                ? String(pair[1]).trimmingCharacters(in: CharacterSet(charactersIn: " \\\""))
                : ""
            directives[String(name)] = value
        }
    }

    static func httpDate(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
        return formatter.date(from: value)
    }

}
