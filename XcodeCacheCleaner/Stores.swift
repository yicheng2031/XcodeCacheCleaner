//
//  Stores.swift
//  XcodeCacheCleaner
//
//  简单持久化：UserDefaults 存偏好与扫描快照（JSON）。
//

import Foundation

final class PreferencesStore {
    // v4：title/description 字段改为本地化 key，直接重置旧偏好以避免混用
    private let key = "preferences.v4"
    private let defaults = UserDefaults.standard
    
    func load() -> Preferences {
        guard
            let data = defaults.data(forKey: key),
            let value = try? JSONDecoder().decode(Preferences.self, from: data)
        else { return .defaultValue }
        return value
    }
    
    func save(_ value: Preferences) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: key)
    }
}

final class SnapshotStore {
    private let key = "snapshot.v2"
    private let defaults = UserDefaults.standard
    
    func load() -> ScanSnapshot? {
        guard
            let data = defaults.data(forKey: key),
            let value = try? JSONDecoder().decode(ScanSnapshot.self, from: data)
        else { return nil }
        return value
    }
    
    func save(_ snapshot: ScanSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: key)
    }
}
