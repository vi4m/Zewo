import HTTPServer

let router = BasicRouter { route in
    route.get("/old-file") { request in
        let file = try FileDescriptorStream(path: "/Users/paulofaria/Desktop/book.pdf")
        return Response(body: file)
    }

    route.get("/new-file") { request in
        let file = try File(path: "/Users/paulofaria/Desktop/book.pdf")
        return Response(body: file)
    }
}

let server = try Server(port: 8888, responder: router)
try server.start()

