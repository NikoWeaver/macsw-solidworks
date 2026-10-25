import Foundation

/// 介质挂载结果。复用别人（Finder 或上次运行）已经挂好的卷时不属于我们，
/// 安装结束也不能把它卸载，否则会把用户桌面上正挂着的盘踢掉。
public struct MountedMedia: Equatable, Sendable {
    public let mountPoint: URL
    public let isOurs: Bool

    public init(mountPoint: URL, isOurs: Bool) {
        self.mountPoint = mountPoint
        self.isOurs = isOurs
    }
}

public final class IsoService: @unchecked Sendable {
    public static let shared = IsoService()
    private let wine: WineService

    public init(wine: WineService = .shared) {
        self.wine = wine
    }

    public func mount(_ iso: URL) async throws -> MountedMedia {
        if let existing = try await existingMountPoint(of: iso) {
            return MountedMedia(mountPoint: existing, isOurs: false)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = ["attach", iso.path, "-nobrowse", "-plist"]
        let capture = try await wine.capturePairCancellable(process)
        guard capture.status == 0 else {
            let reason = failingReason(from: capture)
            throw error(reason.isEmpty ? "Failed to mount the install media." : "Failed to mount the install media: \(reason)")
        }
        do {
            guard let mountPoint = try mountPoint(in: capture.standardOutput) else {
                throw error("The install media is mounted, but its mount path could not be determined.")
            }
            return MountedMedia(mountPoint: mountPoint, isOurs: true)
        } catch {
            // 卷已经挂上了，调用方收到抛错就不会再走 unmount，只能自己收拾，否则每次重试都留一个孤儿卷。
            if let mountPoint = try? await existingMountPoint(of: iso) {
                unmount(MountedMedia(mountPoint: mountPoint, isOurs: true))
            }
            throw error
        }
    }

    /// 只弹出我们自己挂上去的卷；返回非 0 时由调用方提示用户手动推出。
    @discardableResult
    public func unmount(_ mounted: MountedMedia) -> Int32 {
        guard mounted.isOurs else { return 0 }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = ["detach", mounted.mountPoint.path, "-force"]
        guard let status = try? runProcess(process) else { return -1 }
        return status
    }

    /// 该镜像是否已经挂在某处；已挂载时再 attach 会得到"资源暂时不可用"。
    func existingMountPoint(of iso: URL, fileManager: FileManager = .default) async throws -> URL? {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: iso.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            return nil
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = ["info", "-plist"]
        let output = try await wine.capturePairCancellable(process).standardOutput
        guard let images = try plist(output)?["images"] as? [[String: Any]] else { return nil }
        for image in images {
            guard let path = image["image-path"] as? String,
                  path.caseInsensitiveCompare(iso.path) == .orderedSame,
                  let entities = image["system-entities"] as? [[String: Any]] else { continue }
            if let mount = entities.lazy.compactMap({ $0["mount-point"] as? String }).first {
                return URL(fileURLWithPath: mount, isDirectory: true)
            }
        }
        return nil
    }

    /// The disk image (a DMG) that `item` lies on, when its volume is a mounted image; nil otherwise.
    /// The team wizard looks for the team config next to the DMG that MacSW runs from.
    public func diskImage(containing item: URL) async -> URL? {
        guard let volume = try? item.resourceValues(forKeys: [.volumeURLKey]).volume,
              volume.path.hasPrefix("/Volumes/") else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = ["info", "-plist"]
        guard let output = try? await wine.capturePairCancellable(process).standardOutput,
              let images = (try? plist(output))?["images"] as? [[String: Any]] else { return nil }
        for image in images {
            guard let path = image["image-path"] as? String,
                  let entities = image["system-entities"] as? [[String: Any]] else { continue }
            let mountPoints = entities.compactMap { $0["mount-point"] as? String }
            if mountPoints.contains(where: { URL(fileURLWithPath: $0).standardizedFileURL == volume.standardizedFileURL }) {
                return URL(fileURLWithPath: path)
            }
        }
        return nil
    }

    private func mountPoint(in plistText: String) throws -> URL? {
        guard let root = try plist(plistText),
              let entities = root["system-entities"] as? [[String: Any]] else { return nil }
        guard let path = entities.lazy.compactMap({ $0["mount-point"] as? String }).first else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private func plist(_ text: String) throws -> [String: Any]? {
        let data = Data(text.utf8)
        return try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    }

    private func failingReason(from capture: (status: Int32, standardOutput: String, standardError: String)) -> String {
        [capture.standardError, capture.standardOutput]
            .flatMap { $0.split(whereSeparator: \.isNewline).map(String.init) }
            .last { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
    }

    private func runProcess(_ process: Process) throws -> Int32 {
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    private func error(_ message: String) -> NSError {
        MacSWError.make(message, domain: "MacSW.ISO")
    }
}
