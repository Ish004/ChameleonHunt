//
//  sounds — writes each of the game's sound effects (Core/SoundSynth.swift) to a WAV
//  file, to listen to them without building the app:  sounds <outdir>
//

import Foundation

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

func wav(_ samples: [Float], rate: Int) -> Data {
    var data = Data()
    func add<T: FixedWidthInteger>(_ v: T) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    let bytes = samples.count * 2
    data.append(contentsOf: Array("RIFF".utf8)); add(UInt32(36 + bytes)); data.append(contentsOf: Array("WAVE".utf8))
    data.append(contentsOf: Array("fmt ".utf8)); add(UInt32(16)); add(UInt16(1)); add(UInt16(1))
    add(UInt32(rate)); add(UInt32(rate * 2)); add(UInt16(2)); add(UInt16(16))
    data.append(contentsOf: Array("data".utf8)); add(UInt32(bytes))
    for s in samples { add(Int16(max(-1, min(1, s)) * 32767)) }
    return data
}

for effect in SoundEffect.allCases {
    let path = "\(outDir)/\(effect.rawValue).wav"
    try! wav(SoundSynth.render(effect), rate: Int(SoundSynth.sampleRate)).write(to: URL(fileURLWithPath: path))
    print("wrote \(path)")
}
