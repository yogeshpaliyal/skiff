import Foundation

/**
 * Finds the TVs on the Wi-Fi, by what they announce (Bonjour / mDNS), so there's no address to type:
 *  - "_androidtvremote2._tcp", the Google TV remote service: the TV's name ("Living room TV"). Every Google TV has it.
 *  - "_adb._tcp" on port 5555: ADB over the network. Present only with USB debugging on.
 * Matched by address. iOS asks once to allow finding devices on the local network (Info.plist lists both services).
 * Used from the main thread; `onChange` is called there. (TvFinder.kt)
 */
final class TvFinder: NSObject, NetServiceBrowserDelegate, NetServiceDelegate {
    struct Tv: Equatable, Identifiable {
        var host: String
        var name: String
        var ready: Bool
        var id: String { host }
    }

    private static let remoteType = "_androidtvremote2._tcp."
    private static let adbType = "_adb._tcp."

    private let onChange: ([Tv]) -> Void
    private var browsers: [NetServiceBrowser] = []
    private var resolving: [NetService] = []
    private var names: [(String, String)] = []     // host → name, in the order found
    private var adb = Set<String>()

    init(onChange: @escaping ([Tv]) -> Void) {
        self.onChange = onChange
    }

    func start() {
        stop()
        names = []
        adb = []
        for type in [TvFinder.remoteType, TvFinder.adbType] {
            let b = NetServiceBrowser()
            b.delegate = self
            b.searchForServices(ofType: type, inDomain: "local.")
            browsers.append(b)
        }
        publish()
    }

    func stop() {
        for b in browsers { b.stop() }
        browsers = []
        for s in resolving { s.stop() }
        resolving = []
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        service.delegate = self
        resolving.append(service)
        service.resolve(withTimeout: 5)
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        resolving.removeAll { $0 === sender }
        guard let host = TvFinder.ipv4(sender.addresses ?? []), !TvFinder.ownAddresses().contains(host) else { return }
        if sender.type.contains("androidtvremote") {
            if let i = names.firstIndex(where: { $0.0 == host }) { names[i].1 = sender.name } else { names.append((host, sender.name)) }
        } else if sender.port == 5555 {
            adb.insert(host)
        }
        publish()
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        resolving.removeAll { $0 === sender }
    }

    private func publish() {
        var hosts = names.map(\.0)
        for h in adb.sorted() where !hosts.contains(h) { hosts.append(h) }
        let tvs = hosts.map { h in Tv(host: h, name: names.first { $0.0 == h }?.1 ?? "Android TV", ready: adb.contains(h)) }
        // Ready (USB debugging) first, otherwise as found.
        onChange(tvs.filter(\.ready) + tvs.filter { !$0.ready })
    }

    /** The first IPv4 address among a service's (sockaddr structures). */
    private static func ipv4(_ addresses: [Data]) -> String? {
        for data in addresses {
            let host: String? = data.withUnsafeBytes { raw in
                guard let base = raw.baseAddress, raw.count >= MemoryLayout<sockaddr_in>.size else { return nil }
                let sa = base.assumingMemoryBound(to: sockaddr.self)
                guard sa.pointee.sa_family == sa_family_t(AF_INET) else { return nil }
                var sin = base.assumingMemoryBound(to: sockaddr_in.self).pointee
                var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                guard inet_ntop(AF_INET, &sin.sin_addr, &buf, socklen_t(INET_ADDRSTRLEN)) != nil else { return nil }
                return String(cString: buf)
            }
            if let host { return host }
        }
        return nil
    }

    /** This phone's own IPv4 addresses (never itself). */
    static func ownAddresses() -> Set<String> {
        var out = Set<String>()
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return out }
        defer { freeifaddrs(list) }
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = p {
            if let addr = cur.pointee.ifa_addr, addr.pointee.sa_family == sa_family_t(AF_INET) {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                    out.insert(String(cString: host))
                }
            }
            p = cur.pointee.ifa_next
        }
        return out
    }
}
