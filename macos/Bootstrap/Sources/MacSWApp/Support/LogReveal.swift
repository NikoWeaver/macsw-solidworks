import AppKit
import Foundation
import MacSWCore

/// "查看日志"在各处都是同一件事：目录可能还没建，先建再交给访达。
enum LogReveal {
    static func open(_ directory: URL) {
        try? LogFiles.prepareDirectory(directory)  // 0700, like every MacSW logs directory
        NSWorkspace.shared.open(directory)
    }
}
