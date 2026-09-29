import CryptoKit
import Foundation

// One authenticated connection: HMAC-SHA256 challenge-response, HKDF session keys, AES-256-GCM frames.
final class SecureChannel: @unchecked Sendable {
    private static let magic: [UInt8] = Array("CPFS".utf8)
    private static let helloSize = 46
    private static let welcomeSize = 70

    let socket: TCPSocket
    let peerRole: UInt8
    let keyID: Data
    private let sendKey: SymmetricKey
    private let receiveKey: SymmetricKey
    private var sendCounter: UInt64 = 0
    private var receiveCounter: UInt64 = 0
    private let inBuffer = UnsafeMutableRawBufferPointer.allocate(byteCount: Wire.maxPlain + Wire.tagSize, alignment: 16)

    private init(socket: TCPSocket, key: Data, salt: Data, isClient: Bool, peerRole: UInt8, keyID: Data) {
        self.socket = socket
        self.peerRole = peerRole
        self.keyID = keyID
        let master = SymmetricKey(data: key)
        let c2s = HKDF<SHA256>.deriveKey(inputKeyMaterial: master, salt: salt, info: Data("cpfs c2s".utf8), outputByteCount: 32)
        let s2c = HKDF<SHA256>.deriveKey(inputKeyMaterial: master, salt: salt, info: Data("cpfs s2c".utf8), outputByteCount: 32)
        sendKey = isClient ? c2s : s2c
        receiveKey = isClient ? s2c : c2s
        socket.setTimeout(Wire.ioTimeout)
    }

    deinit { inBuffer.deallocate() }

    static func keyID(for key: Data) -> Data { Data(SHA256.hash(data: key).prefix(8)) }

    static func randomBytes(_ count: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }

    // keyID can be overridden so tests present a known id with the wrong key.
    static func connect(host: String, port: UInt16, timeout: TimeInterval, key: Data, keyID: Data? = nil, role: UInt8) throws -> SecureChannel {
        let socket = try TCPSocket.connect(host: host, port: port, timeout: timeout)
        socket.setTimeout(Wire.handshakeTimeout)
        do {
            return try clientHandshake(socket: socket, key: key, keyID: keyID ?? Self.keyID(for: key), role: role)
        } catch {
            socket.close()
            throw error
        }
    }

    static func accept(socket: TCPSocket, role: UInt8, lookup: (Data) -> Data?) throws -> SecureChannel {
        socket.setTimeout(Wire.handshakeTimeout)
        var hello = [UInt8](repeating: 0, count: helloSize)
        _ = try hello.withUnsafeMutableBytes { try socket.readExactly($0.baseAddress!, helloSize) }
        try checkPreamble(hello)
        let keyID = Data(hello[6..<14])
        guard let key = lookup(keyID) else { throw AuthError("chave de pareamento desconhecida") }
        var welcome = magic + [Wire.version, role] + [UInt8](randomBytes(32))
        let transcript = Data(hello + welcome)
        welcome += mac(key, "cpfs-s", transcript)
        try welcome.withUnsafeBytes { try socket.write($0.baseAddress!, $0.count) }
        var proof = [UInt8](repeating: 0, count: 32)
        _ = try proof.withUnsafeMutableBytes { try socket.readExactly($0.baseAddress!, 32) }
        guard constantTimeEqual(proof, mac(key, "cpfs-c", transcript)) else { throw AuthError("prova de pareamento inválida") }
        return SecureChannel(socket: socket, key: key, salt: Data(hello[14..<46] + welcome[6..<38]), isClient: false, peerRole: hello[5], keyID: keyID)
    }

    private static func clientHandshake(socket: TCPSocket, key: Data, keyID: Data, role: UInt8) throws -> SecureChannel {
        let hello = magic + [Wire.version, role] + [UInt8](keyID) + [UInt8](randomBytes(32))
        try hello.withUnsafeBytes { try socket.write($0.baseAddress!, $0.count) }
        var welcome = [UInt8](repeating: 0, count: welcomeSize)
        do {
            _ = try welcome.withUnsafeMutableBytes { try socket.readExactly($0.baseAddress!, welcomeSize) }
        } catch {
            throw AuthError("o destino não reconhece este pareamento")
        }
        try checkPreamble(welcome)
        let transcript = Data(hello + welcome[0..<38])
        guard constantTimeEqual(Array(welcome[38..<70]), mac(key, "cpfs-s", transcript)) else { throw AuthError("a chave de pareamento não confere") }
        let proof = mac(key, "cpfs-c", transcript)
        try proof.withUnsafeBytes { try socket.write($0.baseAddress!, $0.count) }
        return SecureChannel(socket: socket, key: key, salt: Data(hello[14..<46] + welcome[6..<38]), isClient: true, peerRole: welcome[5], keyID: keyID)
    }

    private static func checkPreamble(_ message: [UInt8]) throws {
        guard Array(message[0..<4]) == magic else { throw TransferError("protocolo desconhecido") }
        guard message[4] == Wire.version else { throw TransferError("versão de protocolo incompatível: \(message[4])") }
    }

    private static func mac(_ key: Data, _ label: String, _ transcript: Data) -> [UInt8] {
        Array(HMAC<SHA256>.authenticationCode(for: Data(label.utf8) + transcript, using: SymmetricKey(data: key)))
    }

    private static func constantTimeEqual(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        guard a.count == b.count else { return false }
        return zip(a, b).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }

    private static func nonce(_ counter: UInt64) -> AES.GCM.Nonce {
        var bytes = [UInt8](repeating: 0, count: 12)
        withUnsafeBytes(of: counter.bigEndian) { for i in 0..<8 { bytes[4 + i] = $0[i] } }
        return try! AES.GCM.Nonce(data: bytes)
    }

    func send(_ plaintext: UnsafeRawBufferPointer) throws {
        guard plaintext.count <= Wire.maxPlain else { throw TransferError("quadro grande demais") }
        let header = withUnsafeBytes(of: UInt32(plaintext.count + Wire.tagSize).bigEndian) { Data($0) }
        let box = try AES.GCM.seal(plaintext, using: sendKey, nonce: Self.nonce(sendCounter), authenticating: header)
        sendCounter += 1
        try header.withUnsafeBytes { head in
            try box.ciphertext.withUnsafeBytes { body in
                try box.tag.withUnsafeBytes { tag in try socket.write([head, body, tag]) }
            }
        }
    }

    func send(_ writer: ByteWriter) throws {
        try writer.bytes.withUnsafeBytes { try send($0) }
    }

    // nil means the peer closed cleanly between frames.
    func receive() throws -> Data? {
        var header = [UInt8](repeating: 0, count: 4)
        let started = try header.withUnsafeMutableBytes { try socket.readExactly($0.baseAddress!, 4, allowEOF: true) }
        guard started else { return nil }
        let sealed = Int(header.withUnsafeBytes { UnsafeRawPointer($0.baseAddress!).loadBE32(at: 0) })
        guard sealed >= Wire.tagSize, sealed <= Wire.maxPlain + Wire.tagSize else { throw TransferError("quadro inválido") }
        let base = inBuffer.baseAddress!
        _ = try socket.readExactly(base, sealed)
        let ciphertext = Data(bytesNoCopy: base, count: sealed - Wire.tagSize, deallocator: .none)
        let tag = Data(bytesNoCopy: base + sealed - Wire.tagSize, count: Wire.tagSize, deallocator: .none)
        do {
            let box = try AES.GCM.SealedBox(nonce: Self.nonce(receiveCounter), ciphertext: ciphertext, tag: tag)
            receiveCounter += 1
            return try AES.GCM.open(box, using: receiveKey, authenticating: Data(header))
        } catch {
            throw TransferError("quadro adulterado ou fora de ordem")
        }
    }

    var remoteHost: String? { socket.remoteHost }

    func abort() { socket.abort() }

    func close() { socket.close() }
}
