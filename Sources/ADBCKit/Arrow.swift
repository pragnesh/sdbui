import CADBC
import Foundation

/// A decoded Arrow value, detached from the underlying C buffers.
public indirect enum ArrowValue: Sendable, Equatable, CustomStringConvertible {
    case null
    case bool(Bool)
    case int(Int64)
    case uint(UInt64)
    case double(Double)
    case string(String)
    case binary([UInt8])
    /// Already formatted for display (dates, decimals, intervals, …).
    case formatted(String)
    case list([ArrowValue])
    case structure([Field])

    public struct Field: Sendable, Equatable {
        public var name: String
        public var value: ArrowValue
    }

    public var isNull: Bool { self == .null }

    public var string: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public subscript(field name: String) -> ArrowValue {
        guard case .structure(let fields) = self else { return .null }
        return fields.first { $0.name == name }?.value ?? .null
    }

    public var elements: [ArrowValue] {
        if case .list(let values) = self { return values }
        return []
    }

    public var description: String {
        switch self {
            case .null: return "NULL"
            case .bool(let value): return value ? "true" : "false"
            case .int(let value): return String(value)
            case .uint(let value): return String(value)
            case .double(let value): return String(value)
            case .string(let value): return value
            case .formatted(let value): return value
            case .binary(let bytes):
                let hex = bytes.prefix(64).map { String(format: "%02x", $0) }.joined()
                return "\\x" + hex + (bytes.count > 64 ? "…" : "")
            case .list(let values):
                return "[" + values.map(\.nestedDescription).joined(separator: ", ") + "]"
            case .structure(let fields):
                return "{" + fields.map { "\($0.name): \($0.value.nestedDescription)" }
                    .joined(separator: ", ") + "}"
        }
    }

    private var nestedDescription: String {
        if case .string(let value) = self { return "\"\(value)\"" }
        return description
    }
}

/// Schema of an Arrow field, copied out of an `ArrowSchema`.
public struct ArrowField: Sendable {
    public var name: String
    public var format: String
    public var nullable: Bool
    public var children: [ArrowField]
    private var dictionaryStorage: [ArrowField]

    public var dictionary: ArrowField? { dictionaryStorage.first }

    init(_ schema: UnsafePointer<ArrowSchema>) {
        let raw = schema.pointee
        name = raw.name.map { String(cString: $0) } ?? ""
        format = String(cString: raw.format)
        nullable = raw.flags & Int64(ARROW_FLAG_NULLABLE) != 0
        children = (0..<Int(raw.n_children)).compactMap { index in
            raw.children[index].map { ArrowField(UnsafePointer($0)) }
        }
        dictionaryStorage = raw.dictionary.map { [ArrowField(UnsafePointer($0))] } ?? []
    }

    /// A readable type name, e.g. `int64`, `timestamp[us, UTC]`, `list<utf8>`.
    public var typeName: String {
        if let dictionary {
            return "dictionary<\(dictionary.typeName)>"
        }
        let simple: [String: String] = [
            "n": "null", "b": "bool", "c": "int8", "C": "uint8", "s": "int16", "S": "uint16",
            "i": "int32", "I": "uint32", "l": "int64", "L": "uint64", "e": "float16",
            "f": "float32", "g": "float64", "z": "binary", "Z": "large_binary", "u": "utf8",
            "U": "large_utf8", "vu": "utf8_view", "vz": "binary_view", "tdD": "date32",
            "tdm": "date64", "tts": "time32[s]", "ttm": "time32[ms]", "ttu": "time64[us]",
            "ttn": "time64[ns]", "tDs": "duration[s]", "tDm": "duration[ms]",
            "tDu": "duration[us]", "tDn": "duration[ns]", "tiM": "interval[months]",
            "tiD": "interval[day_time]", "tin": "interval[month_day_nano]",
        ]
        if let name = simple[format] { return name }
        if format.hasPrefix("ts") {
            let unit = format.dropFirst(2).prefix(1)
            let zone = format.split(separator: ":", maxSplits: 1).dropFirst().first ?? ""
            let units = ["s": "s", "m": "ms", "u": "us", "n": "ns"]
            return "timestamp[\(units[String(unit)] ?? String(unit))\(zone.isEmpty ? "" : ", \(zone)")]"
        }
        if format.hasPrefix("d:") { return "decimal(\(format.dropFirst(2)))" }
        if format.hasPrefix("w:") { return "fixed_binary(\(format.dropFirst(2)))" }
        let child = children.first?.typeName ?? "?"
        switch format {
            case "+l", "+L": return "list<\(child)>"
            case "+s": return "struct<" + children.map { "\($0.name): \($0.typeName)" }.joined(separator: ", ") + ">"
            case "+m": return "map"
            default:
                if format.hasPrefix("+w:") { return "fixed_list<\(child), \(format.dropFirst(3))>" }
                if format.hasPrefix("+u") { return "union" }
                return format
        }
    }
}

/// A read-only view over an imported `ArrowArray` and its schema.
///
/// Instances borrow the C buffers: they must not outlive the release of the
/// top-level array they were created from.
final class ArrowArrayView {
    let field: ArrowField
    private let array: ArrowArray
    let children: [ArrowArrayView]
    private let dictionary: ArrowArrayView?
    private lazy var timeZone: TimeZone? = {
        guard let zone = field.format.split(separator: ":", maxSplits: 1).dropFirst().first,
            !zone.isEmpty
        else { return nil }
        return TimeZone(identifier: String(zone))
            ?? TimeZone(abbreviation: String(zone))
            ?? Self.parseOffset(String(zone))
    }()

    init(field: ArrowField, array: ArrowArray) {
        self.field = field
        self.array = array
        children = zip(field.children, 0..<Int(array.n_children)).compactMap { child, index in
            array.children[index].map { ArrowArrayView(field: child, array: $0.pointee) }
        }
        if let dictionaryField = field.dictionary, let dictionaryArray = array.dictionary {
            dictionary = ArrowArrayView(field: dictionaryField, array: dictionaryArray.pointee)
        } else {
            dictionary = nil
        }
    }

    var length: Int { Int(array.length) }
    private var offset: Int { Int(array.offset) }

    private func buffer(_ index: Int) -> UnsafeRawPointer? {
        guard index < Int(array.n_buffers), let buffers = array.buffers else { return nil }
        return buffers[index]
    }

    private func load<T>(_ type: T.Type, buffer index: Int, at element: Int) -> T? {
        buffer(index)?.loadUnaligned(fromByteOffset: element * MemoryLayout<T>.stride, as: T.self)
    }

    private func bit(buffer index: Int, at element: Int) -> Bool {
        guard let bitmap = buffer(index) else { return false }
        let byte = bitmap.load(fromByteOffset: element >> 3, as: UInt8.self)
        return byte & (1 << UInt8(element & 7)) != 0
    }

    /// Whether the value at logical index `index` is null.
    func isNull(_ index: Int) -> Bool {
        let format = field.format
        if format == "n" { return true }
        // Unions and run-end encoded arrays have no validity bitmap.
        if format.hasPrefix("+u") || format == "+r" { return false }
        guard array.null_count != 0, buffer(0) != nil else { return false }
        return !bit(buffer: 0, at: index + offset)
    }

    /// Decode the value at logical index `index` (the array offset is applied
    /// here, so callers always pass indices in `0..<length`, or child indices
    /// taken from offset buffers).
    func value(_ index: Int) -> ArrowValue {
        if isNull(index) { return .null }
        let i = index + offset

        if let dictionary {
            guard let key = integer(buffer: 1, at: i, format: field.format) else { return .null }
            return dictionary.value(Int(key))
        }

        let format = field.format
        switch format {
            case "b": return .bool(bit(buffer: 1, at: i))
            case "c", "s", "i", "l": return integer(buffer: 1, at: i, format: format).map(ArrowValue.int) ?? .null
            case "C": return load(UInt8.self, buffer: 1, at: i).map { .uint(UInt64($0)) } ?? .null
            case "S": return load(UInt16.self, buffer: 1, at: i).map { .uint(UInt64($0)) } ?? .null
            case "I": return load(UInt32.self, buffer: 1, at: i).map { .uint(UInt64($0)) } ?? .null
            case "L": return load(UInt64.self, buffer: 1, at: i).map { .uint($0) } ?? .null
            case "e": return load(UInt16.self, buffer: 1, at: i).map { .double(Self.halfToDouble($0)) } ?? .null
            case "f": return load(Float.self, buffer: 1, at: i).map { .double(Double($0)) } ?? .null
            case "g": return load(Double.self, buffer: 1, at: i).map(ArrowValue.double) ?? .null
            case "u": return .string(String(decoding: variableBytes(at: i, large: false), as: UTF8.self))
            case "U": return .string(String(decoding: variableBytes(at: i, large: true), as: UTF8.self))
            case "z": return .binary(Array(variableBytes(at: i, large: false)))
            case "Z": return .binary(Array(variableBytes(at: i, large: true)))
            case "vu": return .string(String(decoding: viewBytes(at: i), as: UTF8.self))
            case "vz": return .binary(Array(viewBytes(at: i)))
            case "tdD":
                return load(Int32.self, buffer: 1, at: i).map { .formatted(Self.formatDate(days: Int64($0))) } ?? .null
            case "tdm":
                return load(Int64.self, buffer: 1, at: i).map {
                    .formatted(Self.formatDate(days: Self.floorDivide($0, 86_400_000)))
                } ?? .null
            case "tts", "ttm":
                return load(Int32.self, buffer: 1, at: i).map {
                    .formatted(Self.formatTime(Int64($0), perSecond: format == "tts" ? 1 : 1_000))
                } ?? .null
            case "ttu", "ttn":
                return load(Int64.self, buffer: 1, at: i).map {
                    .formatted(Self.formatTime($0, perSecond: format == "ttu" ? 1_000_000 : 1_000_000_000))
                } ?? .null
            case "tDs", "tDm", "tDu", "tDn":
                let units = ["tDs": "s", "tDm": "ms", "tDu": "us", "tDn": "ns"]
                return load(Int64.self, buffer: 1, at: i).map { .formatted("\($0)\(units[format]!)") } ?? .null
            case "tiM":
                return load(Int32.self, buffer: 1, at: i).map { .formatted("\($0) months") } ?? .null
            case "tiD":
                guard let days = load(Int32.self, buffer: 1, at: i * 2),
                    let millis = load(Int32.self, buffer: 1, at: i * 2 + 1)
                else { return .null }
                return .formatted("\(days) days \(millis) ms")
            case "tin":
                guard let base = buffer(1) else { return .null }
                let months = base.loadUnaligned(fromByteOffset: i * 16, as: Int32.self)
                let days = base.loadUnaligned(fromByteOffset: i * 16 + 4, as: Int32.self)
                let nanos = base.loadUnaligned(fromByteOffset: i * 16 + 8, as: Int64.self)
                return .formatted("\(months) months \(days) days \(nanos) ns")
            case "+l", "+L":
                let large = format == "+L"
                guard let child = children.first,
                    let start = offsetValue(at: i, large: large),
                    let end = offsetValue(at: i + 1, large: large)
                else { return .null }
                return .list((start..<end).map(child.value))
            case "+m":
                guard let entries = children.first,
                    let start = offsetValue(at: i, large: false),
                    let end = offsetValue(at: i + 1, large: false)
                else { return .null }
                let keys = entries.children.first
                let values = entries.children.dropFirst().first
                return .structure((start..<end).map { entry in
                    ArrowValue.Field(
                        name: keys?.value(entry).description ?? "?",
                        value: values?.value(entry) ?? .null)
                })
            case "+s":
                return .structure(children.map { .init(name: $0.field.name, value: $0.value(i)) })
            default:
                break
        }

        if format.hasPrefix("ts") {
            return load(Int64.self, buffer: 1, at: i).map { .formatted(formatTimestamp($0)) } ?? .null
        }
        if format.hasPrefix("d:") {
            return .formatted(decimal(at: i))
        }
        if format.hasPrefix("w:"), let width = Int(format.dropFirst(2)), let base = buffer(1) {
            let bytes = UnsafeRawBufferPointer(start: base + i * width, count: width)
            return .binary(Array(bytes))
        }
        if format.hasPrefix("+w:"), let size = Int(format.dropFirst(3)), let child = children.first {
            return .list((i * size..<(i + 1) * size).map(child.value))
        }
        if format.hasPrefix("+u") {
            return unionValue(at: i)
        }
        return .formatted("<\(field.typeName)>")
    }

    // MARK: Buffers

    private func integer(buffer index: Int, at element: Int, format: String) -> Int64? {
        switch format {
            case "c": return load(Int8.self, buffer: index, at: element).map(Int64.init)
            case "C": return load(UInt8.self, buffer: index, at: element).map(Int64.init)
            case "s": return load(Int16.self, buffer: index, at: element).map(Int64.init)
            case "S": return load(UInt16.self, buffer: index, at: element).map(Int64.init)
            case "i": return load(Int32.self, buffer: index, at: element).map(Int64.init)
            case "I": return load(UInt32.self, buffer: index, at: element).map(Int64.init)
            case "l": return load(Int64.self, buffer: index, at: element)
            case "L": return load(UInt64.self, buffer: index, at: element).map { Int64(bitPattern: $0) }
            default: return nil
        }
    }

    private func offsetValue(at element: Int, large: Bool) -> Int? {
        large
            ? load(Int64.self, buffer: 1, at: element).map(Int.init)
            : load(Int32.self, buffer: 1, at: element).map(Int.init)
    }

    private func variableBytes(at element: Int, large: Bool) -> UnsafeRawBufferPointer {
        guard let start = offsetValue(at: element, large: large),
            let end = offsetValue(at: element + 1, large: large),
            end > start, let data = buffer(2)
        else { return UnsafeRawBufferPointer(start: nil, count: 0) }
        return UnsafeRawBufferPointer(start: data + start, count: end - start)
    }

    /// Binary/string view layout: 16-byte views, inline if length <= 12.
    private func viewBytes(at element: Int) -> UnsafeRawBufferPointer {
        guard let views = buffer(1) else { return UnsafeRawBufferPointer(start: nil, count: 0) }
        let view = views + element * 16
        let length = Int(view.loadUnaligned(as: Int32.self))
        if length <= 12 {
            return UnsafeRawBufferPointer(start: view + 4, count: length)
        }
        let bufferIndex = Int(view.loadUnaligned(fromByteOffset: 8, as: Int32.self))
        let dataOffset = Int(view.loadUnaligned(fromByteOffset: 12, as: Int32.self))
        guard let data = buffer(2 + bufferIndex) else { return UnsafeRawBufferPointer(start: nil, count: 0) }
        return UnsafeRawBufferPointer(start: data + dataOffset, count: length)
    }

    private func unionValue(at element: Int) -> ArrowValue {
        // Format: +ud:0,1,2 (dense) or +us:0,1,2 (sparse).
        let dense = field.format.hasPrefix("+ud")
        let typeIDs = field.format.split(separator: ":", maxSplits: 1).dropFirst().first?
            .split(separator: ",").compactMap { Int8($0) } ?? []
        guard let typeID = load(Int8.self, buffer: 0, at: element),
            let childIndex = typeIDs.firstIndex(of: typeID) ?? (Int(typeID) < children.count ? Int(typeID) : nil),
            childIndex < children.count
        else { return .null }
        let child = children[childIndex]
        if dense {
            guard let childOffset = load(Int32.self, buffer: 1, at: element) else { return .null }
            return child.value(Int(childOffset))
        }
        return child.value(element)
    }

    // MARK: Formatting

    private func decimal(at element: Int) -> String {
        // Format: d:precision,scale[,bitWidth]
        let parts = field.format.dropFirst(2).split(separator: ",").compactMap { Int($0) }
        let scale = parts.count > 1 ? parts[1] : 0
        let bitWidth = parts.count > 2 ? parts[2] : 128
        let wordCount = bitWidth / 64
        guard wordCount > 0, let base = buffer(1) else { return "?" }
        let words = (0..<wordCount).map {
            base.loadUnaligned(fromByteOffset: (element * wordCount + $0) * 8, as: UInt64.self)
        }
        return Self.formatDecimal(littleEndianWords: words, scale: scale)
    }

    static func formatDecimal(littleEndianWords words: [UInt64], scale: Int) -> String {
        var magnitude = words
        let negative = (words.last ?? 0) >> 63 == 1
        if negative {
            // Two's complement negation.
            var carry = true
            for index in magnitude.indices {
                magnitude[index] = ~magnitude[index]
                if carry {
                    let (sum, overflow) = magnitude[index].addingReportingOverflow(1)
                    magnitude[index] = sum
                    carry = overflow
                }
            }
        }

        // Repeated division by 10^18, most significant word first.
        let chunk: UInt64 = 1_000_000_000_000_000_000
        var chunks: [UInt64] = []
        while magnitude.contains(where: { $0 != 0 }) {
            var remainder: UInt64 = 0
            for index in magnitude.indices.reversed() {
                let (quotient, newRemainder) = chunk.dividingFullWidth((remainder, magnitude[index]))
                magnitude[index] = quotient
                remainder = newRemainder
            }
            chunks.append(remainder)
        }
        var digits = chunks.last.map(String.init) ?? "0"
        for value in chunks.dropLast().reversed() {
            let text = String(value)
            digits += String(repeating: "0", count: 18 - text.count) + text
        }

        if scale > 0 {
            if digits.count <= scale {
                digits = String(repeating: "0", count: scale - digits.count + 1) + digits
            }
            digits.insert(".", at: digits.index(digits.endIndex, offsetBy: -scale))
        } else if scale < 0, digits != "0" {
            digits += String(repeating: "0", count: -scale)
        }
        return negative ? "-" + digits : digits
    }

    private func formatTimestamp(_ value: Int64) -> String {
        let perSecond: Int64
        switch field.format.dropFirst(2).first {
            case "s": perSecond = 1
            case "m": perSecond = 1_000
            case "u": perSecond = 1_000_000
            default: perSecond = 1_000_000_000
        }
        var seconds = Self.floorDivide(value, perSecond)
        let fraction = value - seconds * perSecond
        var suffix = ""
        if let timeZone {
            let offset = timeZone.secondsFromGMT(for: Date(timeIntervalSince1970: TimeInterval(seconds)))
            seconds += Int64(offset)
            let sign = offset < 0 ? "-" : "+"
            suffix = sign + String(format: "%02ld:%02ld", abs(offset) / 3600, abs(offset) % 3600 / 60)
        }
        let days = floorDivide(seconds, 86_400)
        let timeOfDay = (seconds - days * 86_400) * perSecond + fraction
        return Self.formatDate(days: days) + " " + Self.formatTime(timeOfDay, perSecond: perSecond) + suffix
    }

    private func floorDivide(_ a: Int64, _ b: Int64) -> Int64 { Self.floorDivide(a, b) }

    static func floorDivide(_ a: Int64, _ b: Int64) -> Int64 {
        let quotient = a / b
        return (a % b != 0 && (a < 0) != (b < 0)) ? quotient - 1 : quotient
    }

    /// Days since 1970-01-01 → `YYYY-MM-DD` (proleptic Gregorian).
    static func formatDate(days: Int64) -> String {
        // Howard Hinnant's civil_from_days.
        let z = days + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let dayOfEra = z - era * 146_097
        let yearOfEra = (dayOfEra - dayOfEra / 1460 + dayOfEra / 36524 - dayOfEra / 146_096) / 365
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let mp = (5 * dayOfYear + 2) / 153
        let day = dayOfYear - (153 * mp + 2) / 5 + 1
        let month = mp < 10 ? mp + 3 : mp - 9
        let year = yearOfEra + era * 400 + (month <= 2 ? 1 : 0)
        return String(format: "%04lld-%02lld-%02lld", year, month, day)
    }

    /// A time of day expressed in `1/perSecond` units → `HH:MM:SS[.fff…]`.
    static func formatTime(_ value: Int64, perSecond: Int64) -> String {
        let seconds = floorDivide(value, perSecond)
        let fraction = value - seconds * perSecond
        var text = String(
            format: "%02lld:%02lld:%02lld", seconds / 3600, seconds % 3600 / 60, seconds % 60)
        if fraction != 0 {
            let width = String(perSecond).count - 1
            var digits = String(fraction)
            digits = String(repeating: "0", count: width - digits.count) + digits
            while digits.hasSuffix("0") { digits.removeLast() }
            text += "." + digits
        }
        return text
    }

    private static func parseOffset(_ zone: String) -> TimeZone? {
        // "+05:30" / "-0800"
        let sign: Int = zone.hasPrefix("-") ? -1 : 1
        let digits = zone.filter(\.isNumber)
        guard zone.first == "+" || zone.first == "-", digits.count == 4,
            let hours = Int(digits.prefix(2)), let minutes = Int(digits.suffix(2))
        else { return nil }
        return TimeZone(secondsFromGMT: sign * (hours * 3600 + minutes * 60))
    }

    private static func halfToDouble(_ bits: UInt16) -> Double {
        let sign: Double = bits & 0x8000 != 0 ? -1 : 1
        let exponent = Int((bits >> 10) & 0x1F)
        let mantissa = Double(bits & 0x3FF)
        switch exponent {
            case 0: return sign * mantissa * pow(2, -24)
            case 31: return mantissa == 0 ? sign * .infinity : .nan
            default: return sign * (1 + mantissa / 1024) * pow(2, Double(exponent - 15))
        }
    }
}
