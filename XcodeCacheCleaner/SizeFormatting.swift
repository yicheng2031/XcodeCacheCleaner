//
//  SizeFormatting.swift
//  XcodeCacheCleaner
//
//  Shared byte-size formatting for menu, status label, and toast copy.
//

import Foundation

enum SizeFormatting {
    nonisolated static func short(_ bytes: Int64) -> String {
        if bytes <= 0 { return "0 MB" }
        if bytes < 1_000_000 { return "<1 MB" }
        if bytes >= 1_000_000_000 {
            return String(format: "%.1f GB", Double(bytes) / 1_000_000_000.0)
        }
        return String(format: "%.0f MB", Double(bytes) / 1_000_000.0)
    }
    
    nonisolated static func gigabytes(_ bytes: Int64) -> String {
        String(format: "%.1f", Double(bytes) / 1_000_000_000.0)
    }
}
