import Foundation

/// 自然语音服务（Resources/tts_server.py）的 stdio 协议。
///
/// 请求：一行一个 JSON（`{"id","text","voice","lang"}` 合成，`{"cancel": id | "*"}` 取消）。
/// 回复：长度前缀的二进制帧 —— 4 字节大端长度 N，随后 N 字节：kind(1) | id 长度(1) | id(UTF-8) | payload。
public enum NaturalVoiceProtocol {
    /// 菜单 / 偏好里的取值（`voiceSpeechVoice`）。
    public static let preferenceID = "natural:qwen3-serena"
    public static let speaker = "serena"
    public static let sampleRate: Double = 24_000
    /// 单帧上限：超过视为流已错乱（正常一块音频约 48 KB）。
    public static let maxFrameLength = 8 * 1024 * 1024

    public enum Kind: UInt8, Sendable {
        case ready = 0
        /// payload：float32 小端 PCM，24 kHz 单声道。
        case audio = 1
        /// payload：JSON 统计（含 cancelled）。
        case end = 2
        /// payload：UTF-8 错误信息。
        case error = 3
    }

    public struct Frame: Equatable, Sendable {
        public let kind: Kind
        public let id: String
        public let payload: Data

        public init(kind: Kind, id: String, payload: Data = Data()) {
            self.kind = kind
            self.id = id
            self.payload = payload
        }

        /// 编码（测试与服务端格式对照用）。
        public func encoded() -> Data {
            let idBytes = Data(id.utf8.prefix(255))
            var body = Data([kind.rawValue, UInt8(idBytes.count)])
            body.append(idBytes)
            body.append(payload)
            var length = UInt32(body.count).bigEndian
            var out = Data(bytes: &length, count: 4)
            out.append(body)
            return out
        }

        public var text: String { String(decoding: payload, as: UTF8.self) }

        /// end 帧里的 cancelled。
        public var cancelled: Bool {
            guard kind == .end,
                  let json = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else { return false }
            return json["cancelled"] as? Bool ?? false
        }

        /// audio 帧的采样。
        public var samples: [Float] { NaturalVoiceProtocol.floats(payload) }
    }

    public enum DecodeError: Error, Equatable {
        case oversized(Int)
    }

    /// 增量解码：喂入任意切分的字节流，取出完整的帧；未知 kind 的帧跳过。
    public struct Decoder: Sendable {
        private var buffer = Data()

        public init() {}

        public mutating func append(_ data: Data) throws -> [Frame] {
            buffer.append(data)
            var frames: [Frame] = []
            while buffer.count >= 4 {
                let start = buffer.startIndex
                let length = buffer[start..<start + 4].reduce(0) { ($0 << 8) | Int($1) }
                guard length <= NaturalVoiceProtocol.maxFrameLength, length >= 2 else {
                    buffer.removeAll()
                    throw DecodeError.oversized(length)
                }
                guard buffer.count >= 4 + length else { break }
                let body = buffer.subdata(in: start + 4..<start + 4 + length)
                buffer.removeSubrange(start..<start + 4 + length)
                let b = body.startIndex
                let idLength = Int(body[b + 1])
                guard 2 + idLength <= body.count, let kind = Kind(rawValue: body[b]) else { continue }
                let id = String(decoding: body[b + 2..<b + 2 + idLength], as: UTF8.self)
                frames.append(Frame(kind: kind, id: id, payload: body.subdata(in: b + 2 + idLength..<body.endIndex)))
            }
            return frames
        }
    }

    /// float32 小端字节 → 采样。
    public static func floats(_ data: Data) -> [Float] {
        let count = data.count / 4
        var out = [Float](repeating: 0, count: count)
        data.withUnsafeBytes { raw in
            for i in 0..<count {
                out[i] = Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: i * 4, as: UInt32.self)))
            }
        }
        return out
    }

    /// 合成请求（一行 JSON，含换行）。lang：mlx-audio 的 lang_code（"chinese" / "english"）。
    public static func speakRequest(id: String, text: String, voice: String = speaker, lang: String) -> Data {
        line(["id": id, "text": text, "voice": voice, "lang": lang])
    }

    /// 取消请求；id 为 "*" 时取消全部。
    public static func cancelRequest(_ id: String) -> Data {
        line(["cancel": id])
    }

    /// 界面语言 → lang_code。
    public static func langCode(forUILanguage language: String) -> String {
        language.hasPrefix("zh") ? "chinese" : "english"
    }

    private static func line(_ object: [String: String]) -> Data {
        var data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        data.append(0x0A)
        return data
    }
}
