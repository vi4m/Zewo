public enum ContentNegotiationMiddlewareError : Error {
    case noSuitableParser
    case noSuitableSerializer
}

func parserTypes(for mediaType: MediaType, `in` types: [MediaTypeConvertible.Type]) -> [(MediaType, MapParser.Type)] {
    var parsers: [(MediaType, MapParser.Type)] = []

    for type in types {
        if type.mediaType.matches(other: mediaType) {
            parsers.append(type.mediaType, type.parser)
        }
    }

    return parsers
}

func firstParserType(for mediaType: MediaType, `in` types: [MediaTypeConvertible.Type]) throws -> (MediaType, MapParser.Type) {
    for type in types {
        if type.mediaType.matches(other: mediaType) {
            return (type.mediaType, type.parser)
        }
    }

    throw ContentNegotiationMiddlewareError.noSuitableParser
}

func serializerTypes(for mediaType: MediaType, `in` types: [MediaTypeConvertible.Type]) -> [(MediaType, MapSerializer.Type)] {
    var serializers: [(MediaType, MapSerializer.Type)] = []

    for type in types {
        if type.mediaType.matches(other: mediaType) {
            serializers.append(type.mediaType, type.serializer)
        }
    }

    return serializers
}

func firstSerializerType(for mediaType: MediaType, `in` types: [MediaTypeConvertible.Type]) throws -> (MediaType, MapSerializer.Type) {
    for type in types {
        if type.mediaType.matches(other: mediaType) {
            return (type.mediaType, type.serializer)
        }
    }

    throw ContentNegotiationMiddlewareError.noSuitableSerializer
}

func parse(stream: InputStream, deadline: Double, mediaType: MediaType, `in` types: [MediaTypeConvertible.Type]) throws -> (MediaType, Map) {
    let (mediaType, parserType) = try firstParserType(for: mediaType, in: types)

    do {
        let parser = parserType.init(stream: stream)
        let content = try parser.parse(deadline: deadline)
        return (mediaType, content)
    } catch {
        throw ContentNegotiationMiddlewareError.noSuitableParser
    }
}

func parse(buffer: Buffer, deadline: Double, mediaType: MediaType, `in` types: [MediaTypeConvertible.Type]) throws -> (MediaType, Map) {
    var lastError: Error?

    for (mediaType, parserType) in parserTypes(for: mediaType, in: types) {
        do {
            let stream = BufferStream(buffer: buffer)
            let parser = parserType.init(stream: stream)
            let content = try parser.parse(deadline: deadline)
            return (mediaType, content)
        } catch {
            lastError = error
            continue
        }
    }

    if let lastError = lastError {
        throw lastError
    } else {
        throw ContentNegotiationMiddlewareError.noSuitableParser
    }
}

func serializeToStream(from content: Map, deadline: Double, mediaTypes: [MediaType], `in` types: [MediaTypeConvertible.Type]) throws -> (MediaType, (OutputStream) throws -> Void)  {
    for acceptedType in mediaTypes {
        for (mediaType, serializerType) in serializerTypes(for: acceptedType, in: types) {
            return (mediaType, { stream in
                let serializer = serializerType.init(stream: stream)
                try serializer.serialize(content, deadline: deadline)
            })
        }
    }

    throw ContentNegotiationMiddlewareError.noSuitableSerializer
}

func serializeToBuffer(from content: Map, deadline: Double, mediaTypes: [MediaType], `in` types: [MediaTypeConvertible.Type]) throws -> (MediaType, Buffer) {
    var lastError: Error?

    for acceptedType in mediaTypes {
        for (mediaType, serializerType) in serializerTypes(for: acceptedType, in: types) {
            do {
                let stream = BufferStream()
                let serializer = serializerType.init(stream: stream)
                try serializer.serialize(content, deadline: deadline)
                let buffer = stream.buffer
                return (mediaType, buffer)
            } catch {
                lastError = error
                continue
            }
        }
    }

    if let lastError = lastError {
        throw lastError
    } else {
        throw ContentNegotiationMiddlewareError.noSuitableSerializer
    }
}
