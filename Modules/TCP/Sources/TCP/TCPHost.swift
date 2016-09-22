import CLibvenice
import Venice

public enum TCPError : Error {
    case failedToCreateSocket
    case failedToConnectSocket
    case failedToBindSocket
    case failedToListen
    case failedToGetPort
    case acceptTimedOut
    case connectTimedOut
    case writeTimedOut
    case invalidFileDescriptor
}

public final class TCPHost : Host {
    private let socket: FileDescriptor
    public let ip: IP

    public init(configuration: Map) throws {
        let host = configuration["host"].string ?? "0.0.0.0"
        let port = configuration["port"].int ?? 8080
        let backlog = configuration["backlog"].int ?? 128
        let reusePort = configuration["reusePort"].bool ?? false

        let ip = try IP(localAddress: host, port: port)
        (self.socket, self.ip) = try TCPHost.createSocket(ip: ip, backlog: backlog, reusePort: reusePort)
    }

    public func accept(deadline: Double = .never) throws -> Stream {
        return try TCPHost.acceptSocket(socket, deadline: deadline)
    }
}

extension TCPHost {
    fileprivate static func createSocket(ip: IP, backlog: Int, reusePort: Bool) throws -> (FileDescriptor, IP) {
        var address = ip.address
        let s = socket(Int32(address.family), SOCK_STREAM, 0)
        if s == -1 {
            throw TCPError.failedToCreateSocket
        }

        try tune(socket: s)

        if reusePort {
            try TCP.reusePort(socket: s)
        }

        var result = address.withAddressPointer {
            bind(s, $0, socklen_t(address.length))
        }

        if result != 0 {
            throw TCPError.failedToBindSocket
        }

        result = listen(s, Int32(backlog))

        if result != 0 {
            throw TCPError.failedToListen
        }

        if address.port == 0 {
            var length = socklen_t(address.length)
            let result = address.withAddressPointer {
                getsockname(s, $0, &length)
            }

            if result == -1 {
                fdclean(s)
                close(s)
                throw TCPError.failedToGetPort
            }
        }

        let ip = IP(address: address)
        return (s, ip)
    }

    fileprivate static func acceptSocket(_ socket: FileDescriptor, deadline: Double) throws -> TCPConnection {
        var address = IP.Address()
        var length = socklen_t(address.length)
        while true {
            let acceptSocket = address.withAddressPointer {
                Darwin.accept(socket, $0, &length)
            }

            if acceptSocket >= 0 {
                try tune(socket: acceptSocket)
                let ip = IP(address: address)
                return TCPConnection(socket: acceptSocket, ip: ip)
            }

            if errno != EAGAIN && errno != EWOULDBLOCK {
                throw SystemError.lastOperationError!
            }

            do {
                try poll(socket, events: .read, deadline: deadline)
            } catch PollError.timeout {
                throw TCPError.acceptTimedOut
            }
        }
    }
}

func reusePort(socket: FileDescriptor) throws {
    var option = 1
    let result = setsockopt(socket, SOL_SOCKET, SO_REUSEPORT, &option, socklen_t(sizeofValue(option)))

    if result != 0 {
        fdclean(socket)
        close(socket)
        throw TCPError.invalidFileDescriptor
    }
}

func tune(socket: FileDescriptor) throws {
    do {
        var option = fcntl(socket, F_GETFL, 0)

        if option == -1 {
            option = 0
        }

        var result = fcntl(socket, F_SETFL, option | O_NONBLOCK)

        if result != 0 {
            throw TCPError.invalidFileDescriptor
        }

        /*  Allow re-using the same local address rapidly. */
        option = 1
        result = setsockopt(socket, SOL_SOCKET, SO_REUSEADDR, &option, socklen_t(sizeofValue(option)))

        if result != 0 {
            throw TCPError.invalidFileDescriptor
        }

        /* If possible, prevent SIGPIPE signal when writing to the connection
         already closed by the peer. */
        option = 1
        result = setsockopt(socket, SOL_SOCKET, SO_NOSIGPIPE, &option, socklen_t(sizeofValue(option)))

        if result != 0 {
            throw TCPError.invalidFileDescriptor
        }
    } catch {
        fdclean(socket)
        close(socket)
        throw error
    }
}
