import CoreAudio
import Foundation

public struct AudioProcessActivity: Codable, Sendable {
    public let processID: Int32
    public let bundleID: String
    public let inputActive: Bool?
    public let outputActive: Bool?
}

public struct AudioActivitySnapshot: Codable, Sendable {
    public let available: Bool
    public let processes: [AudioProcessActivity]
}

public enum AudioActivityReader {
    public static func snapshot() -> AudioActivitySnapshot {
        var address = property(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else {
            return AudioActivitySnapshot(available: false, processes: [])
        }
        guard size > 0 else { return AudioActivitySnapshot(available: true, processes: []) }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        let status = ids.withUnsafeMutableBytes { bytes in
            AudioObjectGetPropertyData(system, &address, 0, nil, &size, bytes.baseAddress!)
        }
        guard status == noErr else { return AudioActivitySnapshot(available: false, processes: []) }
        let processes = ids.prefix(Int(size) / MemoryLayout<AudioObjectID>.size).compactMap { id -> AudioProcessActivity? in
            guard let pid = number(id, kAudioProcessPropertyPID) else { return nil }
            return AudioProcessActivity(processID: Int32(bitPattern: pid), bundleID: string(id, kAudioProcessPropertyBundleID) ?? "",
                inputActive: number(id, kAudioProcessPropertyIsRunningInput).map { $0 != 0 },
                outputActive: number(id, kAudioProcessPropertyIsRunningOutput).map { $0 != 0 })
        }
        return AudioActivitySnapshot(available: true, processes: processes)
    }

    private static func property(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }
    private static func number(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var address = property(selector), value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }
    private static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = property(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }
}
