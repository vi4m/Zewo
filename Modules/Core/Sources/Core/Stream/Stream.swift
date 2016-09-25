public enum StreamError : Error {
    case closedStream(buffer: Buffer)
    case timeout(buffer: Buffer)
}

public protocol InputStream {
    var closed: Bool { get }
    func open(deadline: Double) throws
    func close()
    
    func read(into: UnsafeMutableBufferPointer<UInt8>, deadline: Double) throws -> Int
    func read(upTo: Int, deadline: Double) throws -> Buffer
}

extension InputStream {
    public func open() throws {
        return try open(deadline: .never)
    }

    public func read(into: UnsafeMutableBufferPointer<UInt8>) throws -> Int {
        return try read(into: into, deadline: .never)
    }
    
    public func read(upTo count: Int, deadline: Double = .never) throws -> Buffer {
        return try Buffer(capacity: count) { try read(into: $0, deadline: deadline) }
    }

    /// Drains the `Stream` and returns the contents in a `Buffer`. At the end of this operation the stream will be closed.
    public func drain(deadline: Double = .never) throws -> Buffer {
        var buffer = Buffer.empty

        while !self.closed, let chunk = try? self.read(upTo: 2048, deadline: deadline), chunk.count > 0 {
            buffer.append(chunk)
        }

        return buffer
    }
}

public protocol OutputStream {
    var closed: Bool { get }
    func open(deadline: Double) throws
    func close()
    
    func write(_ buffer: UnsafeBufferPointer<UInt8>, deadline: Double) throws
    func write(_ buffer: Buffer, deadline: Double) throws
    func write(_ buffer: BufferRepresentable, deadline: Double) throws
    func flush(deadline: Double) throws
}

extension OutputStream {
    public func open() throws {
        return try open(deadline: .never)
    }
    
    public func write(_ buffer: UnsafeBufferPointer<UInt8>) throws {
        try write(buffer, deadline: .never)
    }
    
    public func write(_ buffer: Buffer, deadline: Double = .never) throws {
        guard !buffer.isEmpty else {
            return
        }
        
        var rethrowError: Error? = nil
        buffer.enumerateBytes { bufferPtr, _, stop in
            do {
                try write(bufferPtr, deadline: deadline)
            } catch {
                rethrowError = error
                stop = true
            }
        }
        
        if let error = rethrowError {
            throw error
        }
    }
    
    public func write(_ converting: BufferRepresentable, deadline: Double = .never) throws {
        try write(converting.buffer, deadline: .never)
    }
    
    public func write(_ bytes: [UInt8], deadline: Double = .never) throws {
        guard !bytes.isEmpty else {
            return
        }
        try bytes.withUnsafeBufferPointer { try self.write($0, deadline: deadline) }
    }

    public func flush() throws {
        try flush(deadline: .never)
    }
}

public typealias Stream = InputStream & OutputStream
