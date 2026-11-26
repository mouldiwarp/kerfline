// The hub's HTTP API, the same as 1.0's so SwarfPath, Fretboard and scripts keep working, plus the
// /link WebSocket the agent dials.
//
//   GET    /api/health               {ok, role, name, version, agent}
//   GET    /api/state                everything a window shows
//   GET    /api/library              the library
//   POST   /api/jobs | /api/files    body = G-code; X-Filename, X-Source, X-Group, X-Group-Index,
//                                    X-Folder (percent-encoded) or ?name=&source=&group=&groupIndex=&folder=
//   GET    /api/files/:id            one item
//   GET    /api/files/:id/content    the G-code
//   DELETE /api/files/:id            move it to the Trash
//   POST   /api/command              body = a Command as JSON; from this Mac only (scripts, rehearsals)

import Foundation
import SGCore
import SGLibrary
import HTTPTypes
import Hummingbird
import HummingbirdWebSocket
import Logging
import NIOCore

/// The request context, with the caller's address (commands are taken from this Mac only).
struct HubContext: RequestContext, WebSocketRequestContext, RemoteAddressRequestContext {
    var coreContext: CoreRequestContextStorage
    let webSocket: WebSocketHandlerReference<HubContext>
    let remoteAddress: SocketAddress?

    init(source: ApplicationRequestContextSource) {
        coreContext = .init(source: source)
        webSocket = .init()
        remoteAddress = source.channel.remoteAddress
    }

    var fromThisMac: Bool {
        guard let ip = remoteAddress?.ipAddress else { return false }
        return ip == "127.0.0.1" || ip == "::1" || ip == "::ffff:127.0.0.1"
    }
}

let maxUpload = 64 << 20

func makeHubApplication(instance: Instance, host: String, port: Int, onRunning: @escaping @Sendable (Int) -> Void) -> some ApplicationProtocol {
    let router = Router(context: HubContext.self)
    router.add(middleware: APIMiddleware())

    router.get("/api/health") { _, _ in
        let linked = await instance.isLinked
        return json(Health(ok: true, role: "hub", name: instance.options.name, version: "\(linkProtocolVersion)", agent: linked))
    }
    router.get("/api/state") { _, _ in json(await instance.state()) }
    router.get("/api/library") { _, _ in json(await instance.library.items()) }

    @Sendable func upload(_ request: Request, _ context: HubContext) async throws -> Response {
        var request = request
        let body = try await request.collectBody(upTo: maxUpload)
        func field(_ header: String, _ query: String) -> String? {
            if let v = request.headers[HTTPField.Name(header)!] { return v.removingPercentEncoding ?? v }
            return request.uri.queryParameters[Substring(query)].map(String.init)
        }
        let options = AddOptions(
            name: field("x-filename", "name") ?? "", source: field("x-source", "source") ?? "Upload", group: field("x-group", "group"),
            groupIndex: field("x-group-index", "groupIndex").flatMap { Int($0) }.flatMap { $0 == 0 ? nil : $0 },
            folder: field("x-folder", "folder"))
        do {
            let item = try await instance.upload(Data(buffer: body), options)
            return json(Uploaded(id: item.id, item: item), status: .created)
        } catch {
            return json(ErrorBody(error: error.localizedDescription), status: .badRequest)
        }
    }
    router.post("/api/jobs", use: upload)
    router.post("/api/files", use: upload)

    router.get("/api/files/:id") { _, context in
        let id = try context.parameters.require("id")
        guard let item = await instance.library.item(id) else { return json(ErrorBody(error: "File not found"), status: .notFound) }
        return json(item)
    }
    router.get("/api/files/:id/content") { _, context in
        let id = try context.parameters.require("id")
        guard let item = await instance.library.item(id), let content = await instance.library.content(id) else {
            return json(ErrorBody(error: "File not found"), status: .notFound)
        }
        var headers = HTTPFields()
        headers[.contentType] = "text/plain; charset=utf-8"
        headers[.contentDisposition] = "inline; filename=\"\(item.name.replacingOccurrences(of: "\"", with: ""))\""
        return Response(status: .ok, headers: headers, body: .init(byteBuffer: ByteBuffer(bytes: content)))
    }
    router.delete("/api/files/:id") { _, context in
        let id = try context.parameters.require("id")
        do {
            try await instance.execute(.deleteFile(fileId: id), by: "API")
            return json(Result(ok: true, error: nil))
        } catch {
            return json(Result(ok: false, error: error.localizedDescription), status: .badRequest)
        }
    }

    // Machine commands are for this Mac's own scripts: the other Mac uses the link, and a
    // browser on the network mustn't be able to move the machine.
    router.post("/api/command") { request, context in
        guard context.fromThisMac else { return json(Result(ok: false, error: "Commands are only taken from this Mac"), status: .forbidden) }
        var request = request
        let body = try await request.collectBody(upTo: 1 << 20)
        let cmd: Command
        do { cmd = try JSONDecoder().decode(Command.self, from: Data(buffer: body)) } catch {
            return json(Result(ok: false, error: "Not a command: \(error.localizedDescription)"), status: .badRequest)
        }
        let by = request.headers[HTTPField.Name("x-by")!] ?? "API"
        do {
            try await instance.execute(cmd, by: by)
            return json(Result(ok: true, error: nil))
        } catch {
            return json(Result(ok: false, error: error.localizedDescription), status: .conflict)
        }
    }

    router.ws("/link") { _, _ in
        .upgrade()
    } onUpgrade: { inbound, outbound, _ in
        let conn = LinkConnection()
        await instance.attached(conn)
        await conn.run(inbound: inbound, outbound: outbound) { m in await instance.received(m, on: conn) }
        await instance.detached(conn)
    }

    return Application(
        router: router,
        server: .http1WebSocketUpgrade(
            webSocketRouter: router,
            configuration: WebSocketServerConfiguration(maxFrameSize: linkMaxFrame, autoPing: .enabled(timePeriod: .seconds(20)))),
        configuration: .init(address: .hostname(host, port: port), serverName: nil),
        onServerRunning: { channel in onRunning(channel.localAddress?.port ?? port) },
        logger: Logger(label: "swarfgrbl.hub"))
}

struct Health: Codable {
    var ok: Bool
    var role: String
    var name: String
    var version: String
    var agent: Bool
}

struct Uploaded: Codable {
    var id: String
    var item: LibraryItem
}

struct ErrorBody: Codable {
    var error: String
}

struct Result: Codable {
    var ok: Bool
    var error: String?
}

func json<T: Encodable>(_ value: T, status: HTTPResponse.Status = .ok) -> Response {
    let data = (try? JSONEncoder().encode(value)) ?? Data("{}".utf8)
    var headers = HTTPFields()
    headers[.contentType] = "application/json; charset=utf-8"
    return Response(status: status, headers: headers, body: .init(byteBuffer: ByteBuffer(bytes: data)))
}

/// CORS for browsers (as 1.0), JSON 404s under /api, and a plain 404 elsewhere.
struct APIMiddleware<Context: RequestContext>: RouterMiddleware {
    func handle(_ request: Request, context: Context, next: (Request, Context) async throws -> Response) async throws -> Response {
        if request.method == .options {
            var headers = HTTPFields()
            headers[.accessControlAllowOrigin] = "*"
            headers[.accessControlAllowMethods] = "GET,POST,DELETE,OPTIONS"
            headers[.accessControlAllowHeaders] = "content-type,x-filename,x-source,x-group,x-group-index"
            return Response(status: .noContent, headers: headers)
        }
        var response: Response
        do {
            response = try await next(request, context)
        } catch let error as HTTPError where error.status == .notFound {
            if request.uri.path.hasPrefix("/api/") {
                response = json(ErrorBody(error: "Not found"), status: .notFound)
            } else {
                response = Response(status: .notFound, body: .init(byteBuffer: ByteBuffer(string: "Not found\n")))
            }
        } catch let error as HTTPError {
            throw error
        } catch {
            response = json(ErrorBody(error: error.localizedDescription), status: .internalServerError)
        }
        response.headers[.accessControlAllowOrigin] = "*"
        return response
    }
}
