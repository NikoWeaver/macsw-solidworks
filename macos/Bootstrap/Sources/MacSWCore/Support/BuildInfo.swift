import Foundation

public enum BuildInfo {
    private static func bundleString(_ key: String, fallback: String) -> String {
        guard let value = (Bundle(url: MacSWBundle.url) ?? .main).object(forInfoDictionaryKey: key) as? String,
              !value.isEmpty,
              !value.hasPrefix("@") else {
            return fallback
        }
        return value
    }

    public static let wineVersion = bundleString("MacSWWineVersion", fallback: "unknown")
    public static let monoVersion = bundleString("MacSWMonoVersion", fallback: "unknown")
    public static let monoPatchSHA256 = bundleString("MacSWMonoPatchSHA256", fallback: "unknown")
    public static let monoMscorlibSHA256 = bundleString("MacSWMonoMscorlibSHA256", fallback: "unknown")
    public static let monoRegAsmX86SHA256 = bundleString("MacSWMonoRegAsmX86SHA256", fallback: "unknown")
    public static let monoRegAsmX64SHA256 = bundleString("MacSWMonoRegAsmX64SHA256", fallback: "unknown")
    public static let stdoleVersion = bundleString("MacSWStdoleVersion", fallback: "unknown")
    public static let stdoleSHA256 = bundleString("MacSWStdoleSHA256", fallback: "unknown")
}
