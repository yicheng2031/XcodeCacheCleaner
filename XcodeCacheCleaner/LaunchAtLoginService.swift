//
//  LaunchAtLoginService.swift
//  XcodeCacheCleaner
//
//  Keeps the menu bar app alive across logins when scheduled cleanup is on.
//

import Foundation
import ServiceManagement

final class LaunchAtLoginService {
    func setEnabled(_ enabled: Bool) throws {
        guard #available(macOS 13.0, *) else { return }

        let service = SMAppService.mainApp
        if enabled {
            guard service.status != .enabled else { return }
            try service.register()
        } else {
            guard service.status == .enabled || service.status == .requiresApproval else { return }
            try service.unregister()
        }
    }
}
