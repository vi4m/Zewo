@_exported import Core
import CLibvenice
import CDNS
import Venice

public enum IPError : Error {
    case invalidPort
    case invalidAddressLiteral
}

public enum DNSError : Error {
    case timeout
    case unableToResolveAddress
}

extension IPError : CustomStringConvertible {
    public var description: String {
        switch self {
        case .invalidPort: return "Port number should be between 0 and 0xffff"
        case .invalidAddressLiteral: return "Invalid IP address literal"
        }
    }
}

public enum IPMode {
    case ipV4
    case ipV6
    case ipV4Prefered
    case ipV6Prefered
}

public func withUnsafeMutablePointer<S, T, Result>(to source: inout S, rebindingMemoryTo target: T.Type, _ body: (UnsafeMutablePointer<T>) throws -> Result) rethrows -> Result {
    return try withUnsafeMutablePointer(to: &source) { pointer in
        try pointer.withMemoryRebound(to: T.self, capacity: MemoryLayout<T>.size) { reboundPointer in
            return try body(reboundPointer)
        }
    }
}

public struct IP {
    public struct Address {
        let data: (Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8)

        public init() {
            self.data = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        }

        public var family: Int {
            var address = self
            return address.withAddressPointer {
                Int($0.pointee.sa_family)
            }
        }

        public var length: Int {
            return family == Int(AF_INET) ? MemoryLayout<sockaddr_in>.size : MemoryLayout<sockaddr_in6>.size
        }

        public var port: Int {
            var address = self
            if address.family == Int(AF_INET) {
                return address.withIPv4Pointer {
                    return Int(_OSSwapInt16($0.pointee.sin_port))
                }
            } else {
                return address.withIPv6Pointer {
                    return Int(_OSSwapInt16($0.pointee.sin6_port))
                }
            }
        }

        fileprivate static func fromIPv4Pointer(body: (UnsafeMutablePointer<sockaddr_in>) throws -> Void) rethrows -> Address {
            var address = Address()
            try withUnsafeMutablePointer(to: &address, rebindingMemoryTo: sockaddr_in.self, body)
            return address
        }

        fileprivate static func fromIPv6Pointer(body: (UnsafeMutablePointer<sockaddr_in6>) throws -> Void) rethrows -> Address {
            var address = Address()
            try withUnsafeMutablePointer(to: &address, rebindingMemoryTo: sockaddr_in6.self, body)
            return address
        }

        public mutating func withAddressPointer<Result>(body: (UnsafeMutablePointer<sockaddr>) throws -> Result) rethrows -> Result {
            return try withUnsafeMutablePointer(to: &self, rebindingMemoryTo: sockaddr.self) {
                try body($0)
            }
        }

        fileprivate mutating func withIPv4Pointer<Result>(body: (UnsafeMutablePointer<sockaddr_in>) throws -> Result) rethrows -> Result {
            return try withUnsafeMutablePointer(to: &self, rebindingMemoryTo: sockaddr_in.self) {
                try body($0)
            }
        }

        fileprivate mutating func withIPv6Pointer<Result>(body: (UnsafeMutablePointer<sockaddr_in6>) throws -> Result) rethrows -> Result {
            return try withUnsafeMutablePointer(to: &self, rebindingMemoryTo: sockaddr_in6.self) {
                try body($0)
            }
        }
    }

    public let address: Address

    public var port: Int {
        return address.port
    }

    public init(address: Address) {
        self.address = address
    }

    public var veniceAddress: ipaddr {
        var source = address
        var veniceAddress = ipaddr()
        withUnsafePointer(to: &source) { source in
            withUnsafeMutablePointer(to: &veniceAddress) { veniceAddress in
                memcpy(veniceAddress, source, MemoryLayout<ipaddr>.size)
                return
            }
        }
        return veniceAddress
    }

    public init(veniceAddress: ipaddr) {
        var source = veniceAddress
        var address = Address()
        withUnsafePointer(to: &source) { source in
            withUnsafeMutablePointer(to: &address) { destination in
                memcpy(destination, source, MemoryLayout<Address>.size)
                return
            }
        }
        self.init(address: address)
    }

    public init(port: Int, mode: IPMode = .ipV4Prefered) throws {
        let address = try IP.ip(port: port, mode: mode)
        self.init(address: address)
    }

    public init(localAddress address: String, port: Int = 0, mode: IPMode = .ipV4Prefered) throws {
        let address = try IP.ip(address: address, port: port, mode: mode)
        self.init(address: address)
    }

    // TODO:
    // public init(interfaceName: String, port: Int = 0, mode: IPMode = .ipV4Prefered) throws {}

    public init(remoteAddress address: String, port: Int, mode: IPMode = .ipV4Prefered, deadline: Double = .never) throws {
        let address = try IP.ip(address: address, port: port, mode: mode, deadline: deadline)
        self.init(address: address)
    }
}

extension IP {
    private static func assertValidPort(_ port: Int) throws {
        if port < 0 || port > 0xffff {
            throw IPError.invalidPort
        }
    }

    fileprivate static func ip(address: String, port: Int, mode: IPMode, deadline: Double) throws -> Address {
        do {
            return try IP.ip(address: address, port: port, mode: mode)
        } catch {
            return try IP.remoteIP(address: address, port: port, mode: mode, deadline: deadline)
        }
    }

    static private var dns_conf: UnsafeMutablePointer<dns_resolv_conf> = {
        var rc: Int32 = 0
        return dns_resconf_local(&rc)!
    }()

    static private var dns_hosts: OpaquePointer = {
        var rc: Int32 = 0
        return dns_hosts_local(&rc)!
    }()

    static private var dns_hints: OpaquePointer = {
        var rc: Int32 = 0
        return dns_hints_local(dns_conf, &rc)!
    }()

    private static func remoteIP(address: String, port: Int, mode: IPMode, deadline: Double) throws -> Address {
        try IP.assertValidPort(port)
        var rc: Int32 = 0
        var dns_opts = dns_options()
        let resolver = dns_res_open(dns_conf, dns_hosts, dns_hints, nil, &dns_opts, &rc)
        var hints = addrinfo()
        hints.ai_family = PF_UNSPEC
        let ai = dns_ai_open(address, String(port), DNS_T_A, &hints, resolver, &rc)!
        defer { dns_ai_close(ai) }
        dns_res_close(resolver)

        var ipv4: UnsafeMutablePointer<addrinfo>? = nil
        var ipv6: UnsafeMutablePointer<addrinfo>? = nil
        var it: UnsafeMutablePointer<addrinfo>? = nil

        loop: while true {
            rc = withUnsafeMutablePointer(to: &it) {
                dns_ai_nextent($0, ai)
            }

            switch rc {
            case EAGAIN:
                let fd = dns_ai_pollfd(ai)
                do {
                    try poll(fd, events: .read, deadline: deadline)
                    // TODO: export this in Venice
                    fdclean(fd)
                    continue loop
                } catch PollError.timeout {
                    throw DNSError.timeout
                }
            case ENOENT:
                break loop
            default:
                if ipv4 == nil,
                    let it = it,
                    it.pointee.ai_family == AF_INET {
                        ipv4 = it
                } else if ipv6 == nil,
                    let it = it,
                    it.pointee.ai_family == AF_INET6 {
                        ipv6 = it
                } else {
                    free(it)
                }

                if ipv4 != nil && ipv6 != nil {
                    break loop
                }
            }
        }

        switch mode {
        case .ipV4:
            if ipv6 != nil {
                free(ipv6)
                ipv6 = nil
            }
        case .ipV6:
            if ipv4 != nil {
                free(ipv4)
                ipv4 = nil
            }
        case .ipV4Prefered:
            if ipv4 != nil && ipv6 != nil {
                free(ipv6)
                ipv6 = nil
            }
        case .ipV6Prefered:
            if ipv6 != nil && ipv4 != nil {
                free(ipv4)
                ipv4 = nil
            }
        }

        if let ipv4 = ipv4 {
            return Address.fromIPv4Pointer { address in
                memcpy(address, ipv4.pointee.ai_addr, MemoryLayout<sockaddr_in>.size)
                address.pointee.sin_port = _OSSwapInt16(__uint16_t(port))
                free(ipv4)
            }
        }

        if let ipv6 = ipv6 {
            return Address.fromIPv6Pointer { address in
                memcpy(address, ipv6.pointee.ai_addr, MemoryLayout<sockaddr_in6>.size)
                address.pointee.sin6_port = _OSSwapInt16(__uint16_t(port))
                free(ipv4)
            }
        }

        throw DNSError.unableToResolveAddress
    }

    fileprivate static func ip(address: String, port: Int, mode: IPMode) throws -> Address {
        try IP.assertValidPort(port)
        switch mode {
        case .ipV4:
            return try IP.ipv4(address: address, port: port)
        case .ipV4Prefered:
            do {
                return try IP.ipv4(address: address, port: port)
            } catch {
                return try IP.ipv6(address: address, port: port)
            }
        case .ipV6:
            return try IP.ipv6(address: address, port: port)
        case .ipV6Prefered:
            do {
                return try IP.ipv6(address: address, port: port)
            } catch {
                return try IP.ipv4(address: address, port: port)
            }
        }
    }

    private static func ipv4(address: String, port: Int) throws -> Address {
        return try Address.fromIPv4Pointer { ipv4 in
            let rc = address.withCString { address in
                inet_pton(AF_INET, address, &ipv4.pointee.sin_addr)
            }
            guard rc == 1 else {
                throw IPError.invalidAddressLiteral
            }
            ipv4.pointee.sin_family = sa_family_t(AF_INET)
            ipv4.pointee.sin_port = _OSSwapInt16(__uint16_t(port))
        }
    }

    private static func ipv6(address: String, port: Int) throws -> Address {
        return try Address.fromIPv6Pointer { ipv6 in
            let rc = address.withCString { address in
                inet_pton(AF_INET6, address, &ipv6.pointee.sin6_addr)
            }
            guard rc == 1 else {
                throw IPError.invalidAddressLiteral
            }
            ipv6.pointee.sin6_family = sa_family_t(AF_INET6)
            ipv6.pointee.sin6_port = _OSSwapInt16(__uint16_t(port))
        }
    }

    fileprivate static func ip(port: Int, mode: IPMode) throws -> Address {
        try IP.assertValidPort(port)
        switch mode {
        case .ipV4, .ipV4Prefered:
            return IP.ipv4(port: port)
        case .ipV6, .ipV6Prefered:
            return IP.ipv6(port: port)
        }
    }

    private static func ipv4(port: Int) -> Address {
        return Address.fromIPv4Pointer { ipv4 in
            ipv4.pointee.sin_family = sa_family_t(AF_INET)
            ipv4.pointee.sin_addr.s_addr = _OSSwapInt32(INADDR_ANY)
            ipv4.pointee.sin_port = _OSSwapInt16(__uint16_t(port))
        }
    }

    private static func ipv6(port: Int) -> Address {
        return Address.fromIPv6Pointer { ipv6 in
            ipv6.pointee.sin6_family = sa_family_t(AF_INET)
            var anyIPv6 = in6addr_any
            memcpy(&ipv6.pointee.sin6_addr, &anyIPv6, MemoryLayout<in6_addr>.size)
            ipv6.pointee.sin6_port = _OSSwapInt16(__uint16_t(port))
        }
    }
}

extension IP : CustomStringConvertible {
    public var description: String {
        var address = self.address
        if address.family == Int(AF_INET) {
            return address.withIPv4Pointer {
                var buffer = [Int8](repeating: 0, count: Int(INET_ADDRSTRLEN))
                let cString = inet_ntop(AF_INET, &$0.pointee.sin_addr, &buffer, socklen_t(INET_ADDRSTRLEN))
                return String(cString: cString!)
            }
        } else {
            return address.withIPv6Pointer {
                var buffer = [Int8](repeating: 0, count: Int(INET6_ADDRSTRLEN))
                let cString = inet_ntop(AF_INET, &$0.pointee.sin6_addr, &buffer, socklen_t(INET6_ADDRSTRLEN))
                return String(cString: cString!)
            }
        }
    }
}
