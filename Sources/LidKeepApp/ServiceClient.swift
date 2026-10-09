import AppKit
import Darwin
import LidKeepCore

/// All connection state and completions are confined to the main queue.
final class ServiceClient {
    var onStatus: ((RuntimeStatus?, String?) -> Void)?
    private var connection: NSXPCConnection?
    private var generation = UUID()
    private var pending: [UUID: (Result<RuntimeStatus, Error>) -> Void] = [:]
    private var latestDate: Date?

    struct ClientError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    func send(_ request: Request, completion: ((Result<RuntimeStatus, Error>) -> Void)? = nil) {
        dispatchPrecondition(condition: .onQueue(.main))
        do {
            let payload = try JSONEncoder().encode(request)
            let connection = try connect()
            let token = generation
            let identifier = UUID()
            pending[identifier] = completion ?? { _ in }
            let proxy = connection.remoteObjectProxyWithErrorHandler { [weak self] error in
                DispatchQueue.main.async { self?.disconnect(error.localizedDescription, generation: token) }
            }
            guard let remote = proxy as? LidKeepXPC else {
                disconnect("后台接口不可用", generation: token)
                return
            }
            remote.request(payload) { [weak self] data in
                DispatchQueue.main.async { self?.receive(data, identifier: identifier, generation: token) }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
                guard let self, self.generation == token, self.pending[identifier] != nil else { return }
                self.disconnect("后台响应超时；正在重连", generation: token)
            }
        } catch {
            onStatus?(nil, error.localizedDescription)
            completion?(.failure(error))
        }
    }

    func invalidate() {
        disconnect("已断开后台连接", generation: generation)
    }

    private func connect() throws -> NSXPCConnection {
        if let connection { return connection }
        let identity = try Self.readIdentity()
        let newConnection = NSXPCConnection(machServiceName: LidKeepPaths.service, options: .privileged)
        newConnection.remoteObjectInterface = NSXPCInterface(with: LidKeepXPC.self)
        newConnection.setCodeSigningRequirement(identity.serviceRequirement)
        let token = UUID()
        generation = token
        latestDate = nil
        newConnection.interruptionHandler = { [weak self] in
            DispatchQueue.main.async { self?.disconnect("后台连接中断；正在重连", generation: token) }
        }
        newConnection.invalidationHandler = { [weak self] in
            DispatchQueue.main.async { self?.disconnect("后台连接失效；正在重连", generation: token) }
        }
        connection = newConnection
        newConnection.activate()
        return newConnection
    }

    private func receive(_ data: Data, identifier: UUID, generation token: UUID) {
        guard generation == token, let completion = pending.removeValue(forKey: identifier) else { return }
        do {
            let response = try JSONDecoder().decode(Response.self, from: data)
            if let status = response.status {
                let age = Date().timeIntervalSince(status.updatedAt)
                guard age <= 15, age >= -5 else {
                    throw ClientError(message: "后台状态已过期；正在重连")
                }
                if latestDate == nil || status.updatedAt >= latestDate! {
                    latestDate = status.updatedAt
                    onStatus?(status, nil)
                }
                if let error = response.error {
                    completion(.failure(ClientError(message: error)))
                } else {
                    completion(.success(status))
                }
            } else if let error = response.error {
                throw ClientError(message: error)
            } else {
                throw ClientError(message: "后台没有返回有效状态")
            }
        } catch {
            completion(.failure(error))
            disconnect(error.localizedDescription, generation: token)
        }
    }

    private func disconnect(_ reason: String, generation token: UUID) {
        guard generation == token else { return }
        generation = UUID()
        let previous = connection
        connection = nil
        previous?.interruptionHandler = nil
        previous?.invalidationHandler = nil
        previous?.invalidate()
        latestDate = nil
        let callbacks = Array(pending.values)
        pending.removeAll()
        onStatus?(nil, reason)
        let error = ClientError(message: reason)
        callbacks.forEach { $0(.failure(error)) }
    }

    private static func readIdentity() throws -> IdentityManifest {
        // Protect the entire trust path, then open the manifest without following a symlink.
        for path in ["/Library", "/Library/Application Support", LidKeepPaths.support] {
            var metadata = stat()
            guard lstat(path, &metadata) == 0,
                  metadata.st_uid == 0,
                  metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
                  metadata.st_mode & 0o022 == 0 else {
                throw ClientError(message: "后台尚未安装或权限异常。请运行 LidKeep 安装包。")
            }
        }
        let descriptor = open(LidKeepPaths.identity, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw ClientError(message: "后台尚未安装。请运行 LidKeep 安装包。")
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              metadata.st_uid == 0,
              metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              metadata.st_mode & 0o022 == 0,
              metadata.st_size > 0, metadata.st_size <= 65_536 else {
            throw ClientError(message: "后台身份文件权限异常，请重新运行安装包。")
        }
        guard let data = try handle.readToEnd() else {
            throw ClientError(message: "无法读取后台身份文件")
        }
        let identity = try JSONDecoder().decode(IdentityManifest.self, from: data)
        guard !identity.serviceRequirement.isEmpty else {
            throw ClientError(message: "后台身份文件无效，请重新运行安装包。")
        }
        return identity
    }
}
