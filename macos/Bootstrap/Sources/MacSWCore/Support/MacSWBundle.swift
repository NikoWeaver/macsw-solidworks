import Foundation

/// The MacSW.app whose Wine runtime, tools and build identity MacSWCore uses.
/// In MacSW itself this is `Bundle.main`. The SOLIDWORKS launcher is a different bundle,
/// so it sets this to the MacSW.app it found before it uses anything else here.
public enum MacSWBundle {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var current = Bundle.main.bundleURL

    public static var url: URL {
        get { lock.lock(); defer { lock.unlock() }; return current }
        set { lock.lock(); current = newValue; lock.unlock() }
    }
}
