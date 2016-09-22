import CLibvenice
import Venice

public final class TCPConnection : Connection {
    public let ip: IP
    private var socket: FileDescriptor?
    public private(set) var closed = true

    internal init(socket: FileDescriptor, ip: IP) {
        self.ip = ip
        self.socket = socket
        self.closed = false
    }

    public init(host: String, port: Int, deadline: Double = .never) throws {
        self.ip = try IP(remoteAddress: host, port: port, deadline: deadline)
        self.socket = nil
    }

    public func open(deadline: Double = .never) throws {
        var address = ip.address
        let socket = Darwin.socket(Int32(address.family), SOCK_STREAM, 0)

        if socket == -1 {
            throw TCPError.failedToCreateSocket
        }

        try tune(socket: socket)

        var result = address.withAddressPointer {
            connect(socket, $0, socklen_t(address.length))
        }

        if result != 0 {
            if errno != EINPROGRESS {
                throw TCPError.failedToConnectSocket
            }

            do {
                try poll(socket, events: .write, deadline: deadline)
            } catch PollError.timeout {
                throw TCPError.connectTimedOut
            }

            var error = 0
            var errorSize = socklen_t(MemoryLayout<Int32>.size)

            result = getsockopt(socket, SOL_SOCKET, SO_ERROR, &error, &errorSize)

            if result != 0 {
                fdclean(socket)
                _ = Darwin.close(socket)
                throw TCPError.failedToConnectSocket
            }

            if error != 0 {
                fdclean(socket)
                _ = Darwin.close(socket)
                throw TCPError.failedToConnectSocket
            }
        }

        self.socket = socket
        self.closed = false
    }

    public func write(_ buffer: Data, length: Int, deadline: Double) throws -> Int {
        let socket = try getSocket()
        try ensureStillOpen()

        while true {
            let bytesWritten = buffer.withUnsafeBytes {
                send(socket, $0, length, 0)
            }

            if bytesWritten == -1 {
                if errno != EAGAIN && errno != EWOULDBLOCK {
                    throw SystemError.lastOperationError!
                }

                do {
                    try poll(socket, events: .write, deadline: deadline)
                } catch PollError.timeout {
                    throw StreamError.timeout(data: Data())
                }

                continue
            }

            return bytesWritten
        }
    }

    public func flush(deadline: Double) throws {
        try getSocket()
        try ensureStillOpen()
    }

    public func read(into buffer: inout Data, length: Int, deadline: Double = .never) throws -> Int {
        let socket = try getSocket()
        try ensureStillOpen()

        while true {
            let bytesRead = buffer.withUnsafeMutableBytes {
                recv(socket, $0, length, 0)
            }

            if bytesRead == 0 {
                close()
                throw StreamError.closedStream(data: Data())
            }

            if bytesRead == -1 {
                if errno != EAGAIN && errno != EWOULDBLOCK {
                    throw SystemError.lastOperationError!
                }

                do {
                    try poll(socket, events: .read, deadline: deadline)
                } catch PollError.timeout {
                    throw StreamError.timeout(data: Data())
                }

                continue
            }

            return bytesRead
        }
    }

    public func close() {
        if !closed, let socket = try? getSocket() {
            fdclean(socket)
            _ = Darwin.close(socket)
        }

        closed = true
    }

    @discardableResult
    private func getSocket() throws -> FileDescriptor {
        guard let socket = self.socket else {
            throw SystemError.socketIsNotConnected
        }
        return socket
    }

    private func ensureStillOpen() throws {
        if closed {
            throw StreamError.closedStream(data: Data())
        }
    }

    deinit {
        close()
    }
}
