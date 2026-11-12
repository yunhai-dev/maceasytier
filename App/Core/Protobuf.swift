import Foundation

/// 极简 protobuf wire 编解码，覆盖 EasyTier RPC 用到的字段类型。
struct ProtoWriter {
    private(set) var data = Data()

    mutating func varint(_ value: UInt64) {
        var value = value
        while true {
            let byte = UInt8(value & 0x7F)
            value >>= 7
            if value == 0 {
                data.append(byte)
                return
            }
            data.append(byte | 0x80)
        }
    }

    mutating func fieldVarint(_ field: Int, _ value: UInt64) {
        varint(UInt64((field << 3) | 0))
        varint(value)
    }

    mutating func fieldBytes(_ field: Int, _ value: Data) {
        varint(UInt64((field << 3) | 2))
        varint(UInt64(value.count))
        data.append(value)
    }

    mutating func fieldString(_ field: Int, _ value: String) {
        fieldBytes(field, Data(value.utf8))
    }

    mutating func fieldMessage(_ field: Int, _ build: (inout ProtoWriter) -> Void) {
        var nested = ProtoWriter()
        build(&nested)
        fieldBytes(field, nested.data)
    }
}

enum ProtoWire: Equatable {
    case varint(UInt64)
    case bytes(Data)
    case fixed32(UInt32)
    case fixed64(UInt64)
}

struct ProtoReader {
    private let data: Data
    private var index: Int

    init(_ data: Data) {
        // Data slices 保留父级 index，这里统一复制成 0 起始，避免下标越界。
        self.data = Data(data)
        self.index = 0
    }

    var isAtEnd: Bool { index >= data.count }

    mutating func next() -> (field: Int, wire: ProtoWire)? {
        guard let tag = readVarint(), tag != 0 else { return nil }
        let field = Int(tag >> 3)
        let wire = Int(tag & 0x07)

        switch wire {
        case 0:
            guard let value = readVarint() else { return nil }
            return (field, .varint(value))
        case 1:
            guard index + 8 <= data.count else { return nil }
            let value = data[index ..< index + 8].reversed().reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            index += 8
            return (field, .fixed64(value))
        case 2:
            guard let length = readVarint(), length <= UInt64(data.count - index) else { return nil }
            let start = index
            index += Int(length)
            return (field, .bytes(data[start ..< index]))
        case 5:
            guard index + 4 <= data.count else { return nil }
            let value = data[index ..< index + 4].reversed().reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            index += 4
            return (field, .fixed32(value))
        default:
            return nil
        }
    }

    private mutating func readVarint() -> UInt64? {
        var value: UInt64 = 0
        var shift: UInt64 = 0
        while index < data.count {
            let byte = data[index]
            index += 1
            value |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return value }
            shift += 7
            if shift >= 64 { return nil }
        }
        return nil
    }
}

extension Data {
    func protoValue(_ field: Int) -> ProtoWire? {
        var reader = ProtoReader(self)
        while let item = reader.next() {
            if item.field == field { return item.wire }
        }
        return nil
    }

    func protoVarint(_ field: Int) -> UInt64? {
        if case let .varint(value)? = protoValue(field) { return value }
        return nil
    }

    func protoBytes(_ field: Int) -> Data? {
        if case let .bytes(value)? = protoValue(field) { return value }
        return nil
    }

    func protoString(_ field: Int) -> String? {
        protoBytes(field).map { String(decoding: $0, as: UTF8.self) }
    }

    func protoFloat(_ field: Int) -> Float? {
        if case let .fixed32(value)? = protoValue(field) {
            return Float(bitPattern: value)
        }
        return nil
    }

    func protoRepeatedBytes(_ field: Int) -> [Data] {
        var result: [Data] = []
        var reader = ProtoReader(self)
        while let item = reader.next() {
            if item.field == field, case let .bytes(value) = item.wire {
                result.append(value)
            }
        }
        return result
    }

    func protoRepeatedVarints(_ field: Int) -> [UInt64] {
        var result: [UInt64] = []
        var reader = ProtoReader(self)
        while let item = reader.next() {
            if item.field == field, case let .varint(value) = item.wire {
                result.append(value)
            }
        }
        return result
    }
}
