import XCTest
import HBHTTPClient
@testable import HummingBird

enum ApplicationTestError: Error {
    case noBody
}

final class ApplicationTests: XCTestCase {

    func testEnvironment() {
        Environment["TEST_ENV"] = "testing"
        XCTAssertEqual(Environment["TEST_ENV"], "testing")
        Environment["TEST_ENV"] = nil
        XCTAssertEqual(Environment["TEST_ENV"], nil)
    }

    func createApp() -> Application {
        let app = Application()
        app.router.get("/hello") { request -> EventLoopFuture<ByteBuffer> in
            let buffer = request.allocator.buffer(string: "GET: Hello")
            return request.eventLoop.makeSucceededFuture(buffer)
        }
        app.router.get("/accepted") { request -> HTTPResponseStatus in
            return .accepted
        }
        app.router.post("/hello") { request in
            return request.allocator.buffer(string: "POST: Hello")
        }
        app.router.get("/query") { request -> EventLoopFuture<ByteBuffer> in
            let buffer = request.allocator.buffer(string: request.uri.query.map { String($0) } ?? "")
            return request.eventLoop.makeSucceededFuture(buffer)
        }
        app.router.post("/echo-body") { request -> Response in
            let body: ResponseBody = request.body.map { .byteBuffer($0) } ?? .empty
            return .init(status: .ok, headers: [:], body: body)
        }
        app.router.post("/echo-body-streaming") { request -> EventLoopFuture<Response> in
            let body: ResponseBody
            if var requestBody = request.body {
                body = .streamCallback { eventLoop in
                    let bytesToDownload = min(32*1024, requestBody.readableBytes)
                    guard bytesToDownload > 0 else { return eventLoop.makeSucceededFuture(.end) }
                    let buffer = requestBody.readSlice(length: bytesToDownload)!
                    return eventLoop.makeSucceededFuture(.byteBuffer(buffer))
                }
            } else {
                body = .empty
            }
            return request.eventLoop.makeSucceededFuture(.init(status: .ok, headers: [:], body: body))
        }
        return app
    }

    func shutdownApp(_ app: Application) {
        app.lifecycle.shutdown()
        app.lifecycle.wait()
    }

    func randomBuffer(size: Int) -> ByteBuffer {
        var data = [UInt8](repeating: 0, count: size)
        data = data.map { _ in UInt8.random(in: 0...255) }
        return ByteBufferAllocator().buffer(bytes: data)
    }

    func testRequest(_ request: HTTPClient.Request, app: Application? = nil, test: @escaping (HTTPClient.Response) throws -> ()) {
        let localApp: Application
        if let app = app {
            localApp = app
        } else {
            localApp = createApp()
            DispatchQueue.global().async {
                localApp.serve()
            }
        }
        defer { if app == nil { shutdownApp(localApp) } }

        let client = HTTPClient(eventLoopGroupProvider: .createNew)
        defer { XCTAssertNoThrow(try client.syncShutdown()) }
        let response = client.execute(request)
            .flatMapThrowing { response in
                try test(response)
            }
        XCTAssertNoThrow(try response.wait())
    }

    func testGetRoute() {
        let request = HTTPClient.Request(uri: "http://localhost:8000/hello", method: .GET, headers: [:])
        testRequest(request) { response in
            guard var body = response.body else { throw ApplicationTestError.noBody }
            let string = body.readString(length: body.readableBytes)
            XCTAssertEqual(response.status, .ok)
            XCTAssertEqual(string, "GET: Hello")
        }
    }

    func testHTTPStatusRoute() {
        let request = HTTPClient.Request(uri: "http://localhost:8000/accepted", method: .GET, headers: [:])
        testRequest(request) { response in
            XCTAssertEqual(response.status, .accepted)
        }
    }

    func testPostRoute() {
        let request = HTTPClient.Request(uri: "http://localhost:8000/hello", method: .POST, headers: [:])
        testRequest(request) { response in
            guard var body = response.body else { throw ApplicationTestError.noBody }
            let string = body.readString(length: body.readableBytes)
            XCTAssertEqual(response.status, .ok)
            XCTAssertEqual(string, "POST: Hello")
        }
    }

    func testQueryRoute() {
        let request = HTTPClient.Request(uri: "http://localhost:8000/query?test=test%20data", method: .GET, headers: [:])
        testRequest(request) { response in
            guard var body = response.body else { throw ApplicationTestError.noBody }
            let string = body.readString(length: body.readableBytes)
            XCTAssertEqual(response.status, .ok)
            XCTAssertEqual(string, "test=test%20data")
        }
    }

    func testResponseBody() {
        let buffer = randomBuffer(size: 140000)
        let request = HTTPClient.Request(uri: "http://localhost:8000/echo-body", method: .POST, headers: [:], body: buffer)
        testRequest(request) { response in
            XCTAssertEqual(response.body, buffer)
        }
    }

    func testResponseBodyStreaming() {
        let buffer = randomBuffer(size: 140000)
        let request = HTTPClient.Request(uri: "http://localhost:8000/echo-body-streaming", method: .POST, headers: [:], body: buffer)
        testRequest(request) { response in
            XCTAssertEqual(response.body, buffer)
        }
    }

    func testMiddleware() {
        struct TestMiddleware: Middleware {
            func apply(to request: Request, next: RequestResponder) -> EventLoopFuture<Response> {
                return next.apply(to: request).map { response in
                    var response = response
                    response.headers.replaceOrAdd(name: "middleware", value: "TestMiddleware")
                    return response
                }
            }
        }
        let app = createApp()
        defer { shutdownApp(app) }
        DispatchQueue.global().async {
            app.serve()
        }

        app.middlewares.add(TestMiddleware())
        let request = HTTPClient.Request(uri: "http://localhost:8000/hello", method: .GET, headers: [:])
        testRequest(request, app: app) { response in
            XCTAssertEqual(response.headers["middleware"].first, "TestMiddleware")
        }
    }

    func testGroupMiddleware() {
        struct TestMiddleware: Middleware {
            func apply(to request: Request, next: RequestResponder) -> EventLoopFuture<Response> {
                return next.apply(to: request).map { response in
                    var response = response
                    response.headers.replaceOrAdd(name: "middleware", value: "TestMiddleware")
                    return response
                }
            }
        }
        let app = createApp()
        DispatchQueue.global().async {
            app.serve()
        }
        defer { shutdownApp(app) }

        let group = app.router.group()
            .add(middleware: TestMiddleware())
        group.get("/group") { request in
            return request.eventLoop.makeSucceededFuture(request.allocator.buffer(string: "hello"))
        }
        app.router.get("/not-group") { request in
            return request.eventLoop.makeSucceededFuture(request.allocator.buffer(string: "hello"))
        }

        let request = HTTPClient.Request(uri: "http://localhost:8000/group", method: .GET, headers: [:])
        testRequest(request, app: app) { response in
            XCTAssertEqual(response.headers["middleware"].first, "TestMiddleware")
        }
        let request2 = HTTPClient.Request(uri: "http://localhost:8000/not-group", method: .GET, headers: [:])
        testRequest(request2, app: app) { response in
            XCTAssertEqual(response.headers["middleware"].first, nil)
        }
    }
}
