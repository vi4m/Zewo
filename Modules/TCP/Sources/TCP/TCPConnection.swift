import POSIX
import Venice

public final class TCPConnection : Connection {
    private var socket: FileDescriptor?

    public private(set) var ip: IP
    public private(set) var closed: Bool

    internal init(socket: FileDescriptor, ip: IP) {
        self.ip = ip
        self.socket = socket
        self.closed = false
    }

    public init(host: String, port: Int, deadline: Double = 1.minute.fromNow()) throws {
        self.ip = try IP(address: host, port: port, deadline: deadline)
        self.socket = nil
        self.closed = true
    }

    public func open(deadline: Double = 1.minute.fromNow()) throws {
        let address = ip.address

        guard let socket = try? POSIX.socket(family: address.family, type: .stream, protocol: 0) else {
            throw TCPError.failedToCreateSocket
        }

        try TCP.tune(socket: socket)

        do {
            try POSIX.connect(socket: socket, address: address)
        } catch SystemError.operationNowInProgress {
            do {
                try poll(socket, events: .write, deadline: deadline)
            } catch PollError.timeout {
                try TCP.close(socket: socket)
                throw TCPError.connectTimedOut
            }
            try POSIX.checkError(socket: socket)
        } catch {
            try TCP.close(socket: socket)
            throw TCPError.failedToConnectSocket
        }

        self.socket = socket
        self.closed = false
    }

    public func write(_ buffer: Data, length: Int, deadline: Double) throws -> Int {
        let socket = try getSocket()
        try ensureStillOpen()

        loop: while true {
            do {
                let bytesWritten = try buffer.withUnsafeBytes {
                    try POSIX.send(socket: socket, buffer: $0, count: length, flags: .noSignal)
                }
                return bytesWritten
            } catch {
                switch error {
                case SystemError.resourceTemporarilyUnavailable, SystemError.operationWouldBlock:
                    do {
                        try poll(socket, events: .write, deadline: deadline)
                    } catch PollError.timeout {
                        throw StreamError.timeout(data: Data())
                    }
                    continue loop
                case SystemError.connectionResetByPeer, SystemError.brokenPipe:
                    close()
                    throw StreamError.closedStream(data: Data())
                default:
                    throw error
                }
            }
        }
    }

    public func flush(deadline: Double) throws {
        try getSocket()
        try ensureStillOpen()
    }

    public func read(into buffer: inout Data, length: Int, deadline: Double = 1.minute.fromNow()) throws -> Int {
        let socket = try getSocket()
        try ensureStillOpen()

        loop: while true {
            do {
                let bytesRead = try buffer.withUnsafeMutableBytes {
                    try POSIX.receive(socket: socket, buffer: $0, count: length)
                }

                if bytesRead == 0 {
                    close()
                    throw StreamError.closedStream(data: Data())
                }

                return bytesRead
            } catch {
                switch error {
                case SystemError.resourceTemporarilyUnavailable, SystemError.operationWouldBlock:
                    do {
                        try poll(socket, events: .read, deadline: deadline)
                    } catch PollError.timeout {
                        throw StreamError.timeout(data: Data())
                    }
                    continue loop
                default:
                    throw error
                }
            }
        }
    }

    public func close() {
        guard !closed, let socket = try? getSocket() else {
            return
        }

        try? TCP.close(socket: socket)
        self.socket = nil
        self.closed = true
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
