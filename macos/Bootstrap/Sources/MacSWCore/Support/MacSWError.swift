import Foundation

/// 面向用户的失败说明统一从这里构造：只有本地化文案，域名用于定位是谁报的。
public enum MacSWError {
    public static func make(_ message: String, domain: String, code: Int = 1) -> NSError {
        NSError(domain: domain, code: code, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
