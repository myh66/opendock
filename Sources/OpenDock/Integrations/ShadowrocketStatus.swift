import AppKit
import Foundation
import SystemConfiguration

struct ShadowrocketProxyEndpoint: Identifiable, Equatable {
    let kind: String
    let host: String?
    let port: Int?
    var id: String { kind }

    var address: String {
        guard let host, let port else { return "地址不可用" }
        let formattedHost = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        return "\(formattedHost):\(port)"
    }

    var isLoopback: Bool {
        guard let host else { return false }
        let value = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if value == "localhost" || value == "localhost." || value == "::1" || value == "0:0:0:0:0:0:0:1" { return true }
        let components = value.split(separator: ".", omittingEmptySubsequences: false)
        let numbers = components.compactMap { Int($0) }
        return components.count == 4 && numbers.count == 4 && numbers.allSatisfy { (0...255).contains($0) } && numbers.first == 127
    }
}

/// A configuration summary, never evidence that a proxy is reachable or that
/// Shadowrocket owns it. PAC URLs/scripts, exceptions and authentication fields
/// are deliberately neither retained nor evaluated.
struct ShadowrocketProxySummary: Equatable {
    var available = false
    var endpoints: [ShadowrocketProxyEndpoint] = []
    var automaticConfiguration = false
    var automaticDiscovery = false
    var hasUnknownFlags = false

    var isConfigured: Bool { !endpoints.isEmpty || automaticConfiguration || automaticDiscovery }
    var summary: String {
        guard available else { return "系统默认代理不可读取" }
        if isConfigured {
            let kinds = endpoints.map(\.kind) + (automaticConfiguration ? ["PAC"] : []) + (automaticDiscovery ? ["自动发现"] : [])
            return "系统代理 · " + kinds.joined(separator: " / ")
        }
        return hasUnknownFlags ? "系统代理标记不可读取" : "系统默认代理未启用"
    }

    static func parse(_ dictionary: [String: Any]?) -> Self {
        guard let dictionary else { return Self() }
        var summary = Self(available: true)
        func enabled(_ key: CFString) -> Bool {
            guard let raw = dictionary[key as String] else { return false }
            guard let number = raw as? NSNumber, number.doubleValue.isFinite, [0.0, 1.0].contains(number.doubleValue) else {
                summary.hasUnknownFlags = true; return false
            }
            return number.doubleValue == 1
        }
        func host(_ key: CFString) -> String? {
            guard let value = dictionary[key as String] as? String else { return nil }
            let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
            // The public property is a hostname, not a URL; reject anything
            // carrying user-info, path/query data, or control characters.
            let forbidden = CharacterSet.whitespacesAndNewlines.union(.controlCharacters).union(CharacterSet(charactersIn: "@/\\?#"))
            guard !clean.isEmpty, clean.count <= 253, clean.rangeOfCharacter(from: forbidden) == nil else { return nil }
            return clean
        }
        func port(_ key: CFString) -> Int? {
            guard let number = dictionary[key as String] as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            let value = number.doubleValue
            guard value.isFinite, value.rounded(.towardZero) == value, (1...65535).contains(value) else { return nil }
            return Int(value)
        }
        let kinds: [(String, CFString, CFString, CFString)] = [
            ("HTTP", kSCPropNetProxiesHTTPEnable, kSCPropNetProxiesHTTPProxy, kSCPropNetProxiesHTTPPort),
            ("HTTPS", kSCPropNetProxiesHTTPSEnable, kSCPropNetProxiesHTTPSProxy, kSCPropNetProxiesHTTPSPort),
            ("SOCKS", kSCPropNetProxiesSOCKSEnable, kSCPropNetProxiesSOCKSProxy, kSCPropNetProxiesSOCKSPort),
            ("FTP", kSCPropNetProxiesFTPEnable, kSCPropNetProxiesFTPProxy, kSCPropNetProxiesFTPPort)
        ]
        for (kind, flag, server, servicePort) in kinds where enabled(flag) {
            summary.endpoints.append(ShadowrocketProxyEndpoint(kind: kind, host: host(server), port: port(servicePort)))
        }
        summary.automaticConfiguration = enabled(kSCPropNetProxiesProxyAutoConfigEnable)
        summary.automaticDiscovery = enabled(kSCPropNetProxiesProxyAutoDiscoveryEnable)
        return summary
    }
}

struct ShadowrocketStatusSnapshot: Equatable {
    var applicationURL: URL?
    var version: String?
    var clientRunning = false
    var proxies = ShadowrocketProxySummary()
    var sampledAt: Date?
    var installed: Bool { applicationURL != nil || clientRunning }
    var clientSummary: String {
        guard sampledAt != nil else { return "检查客户端状态" }
        if clientRunning { return "客户端已运行" }
        return installed ? "客户端未运行" : "尚未安装"
    }
    // Shadowrocket exposes no verified public status API in this integration.
    // A Network Extension may remain active after its containing app exits.
    var connectionSummary: String { "连接状态无法确认" }
}

enum ShadowrocketStatusReader {
    static let bundleIdentifier = "com.liguangming.Shadowrocket"
    static let appStoreURL = URL(string: "https://apps.apple.com/app/shadowrocket/id932747118")!

    static func verifiedApplication(at url: URL) -> Bool {
        url.isFileURL && url.pathExtension.lowercased() == "app" && Bundle(url: url)?.bundleIdentifier == bundleIdentifier
    }

    @MainActor static func read() -> ShadowrocketStatusSnapshot {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).filter { !$0.isTerminated }
        let candidates = [NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)] + running.map(\.bundleURL) + [
            URL(fileURLWithPath: "/Applications/Shadowrocket.app", isDirectory: true),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Shadowrocket.app", isDirectory: true)
        ]
        let application = candidates.compactMap { $0 }.first(where: verifiedApplication)
        let version = application.flatMap { Bundle(url: $0)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String }
        // Public, read-only global settings. This does not fetch a PAC script,
        // inspect personal VPN configurations, or touch any network preferences.
        // https://developer.apple.com/documentation/systemconfiguration/scdynamicstorecopyproxies(_:)
        let dictionary = SCDynamicStoreCopyProxies(nil) as? [String: Any]
        return ShadowrocketStatusSnapshot(applicationURL: application, version: version.map { String($0.prefix(32)) }, clientRunning: !running.isEmpty,
                                         proxies: .parse(dictionary), sampledAt: .now)
    }
}
