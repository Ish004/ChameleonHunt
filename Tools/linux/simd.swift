// A small Linux stand-in for Apple's simd module: just what ChameleonHunt's Core uses,
// so its tests can run off a Mac. Not part of the app.
@_exported import Foundation

public typealias simd_float2 = SIMD2<Float>
public typealias simd_float3 = SIMD3<Float>
public typealias simd_float4 = SIMD4<Float>
public typealias simd_double3 = SIMD3<Double>

public struct simd_float4x4: Equatable, Sendable {
    public var columns: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>)
    public init() { columns = (.zero, .zero, .zero, .zero) }
    public init(_ c0: SIMD4<Float>, _ c1: SIMD4<Float>, _ c2: SIMD4<Float>, _ c3: SIMD4<Float>) { columns = (c0, c1, c2, c3) }
    public init(columns: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>)) { self.columns = columns }
    public init(diagonal d: SIMD4<Float>) {
        columns = (SIMD4(d.x, 0, 0, 0), SIMD4(0, d.y, 0, 0), SIMD4(0, 0, d.z, 0), SIMD4(0, 0, 0, d.w))
    }
    public init(_ q: simd_quatf) {
        let x = q.vector.x, y = q.vector.y, z = q.vector.z, w = q.vector.w
        columns = (SIMD4(1 - 2 * (y * y + z * z), 2 * (x * y + z * w), 2 * (x * z - y * w), 0),
                   SIMD4(2 * (x * y - z * w), 1 - 2 * (x * x + z * z), 2 * (y * z + x * w), 0),
                   SIMD4(2 * (x * z + y * w), 2 * (y * z - x * w), 1 - 2 * (x * x + y * y), 0),
                   SIMD4(0, 0, 0, 1))
    }
    public subscript(column: Int) -> SIMD4<Float> {
        get { switch column { case 0: columns.0; case 1: columns.1; case 2: columns.2; default: columns.3 } }
        set { switch column { case 0: columns.0 = newValue; case 1: columns.1 = newValue; case 2: columns.2 = newValue; default: columns.3 = newValue } }
    }
    public subscript(column: Int, row: Int) -> Float {
        get { self[column][row] }
        set { var c = self[column]; c[row] = newValue; self[column] = c }
    }
    public static func == (a: simd_float4x4, b: simd_float4x4) -> Bool {
        a.columns.0 == b.columns.0 && a.columns.1 == b.columns.1 && a.columns.2 == b.columns.2 && a.columns.3 == b.columns.3
    }
    public var transpose: simd_float4x4 {
        var r = simd_float4x4()
        for c in 0..<4 { for row in 0..<4 { r[row, c] = self[c, row] } }
        return r
    }
    public var inverse: simd_float4x4 {
        // Gauss-Jordan on doubles.
        var m = [[Double]](repeating: [Double](repeating: 0, count: 8), count: 4)
        for row in 0..<4 { for c in 0..<4 { m[row][c] = Double(self[c, row]) }; m[row][4 + row] = 1 }
        for col in 0..<4 {
            var pivot = col
            for r in col..<4 where abs(m[r][col]) > abs(m[pivot][col]) { pivot = r }
            m.swapAt(col, pivot)
            let p = m[col][col]
            guard p != 0 else { continue }
            for k in 0..<8 { m[col][k] /= p }
            for r in 0..<4 where r != col {
                let f = m[r][col]
                if f != 0 { for k in 0..<8 { m[r][k] -= f * m[col][k] } }
            }
        }
        var out = simd_float4x4()
        for row in 0..<4 { for c in 0..<4 { out[c, row] = Float(m[row][4 + c]) } }
        return out
    }
    public static func * (a: simd_float4x4, b: simd_float4x4) -> simd_float4x4 {
        simd_float4x4(a * b.columns.0, a * b.columns.1, a * b.columns.2, a * b.columns.3)
    }
    public static func * (a: simd_float4x4, v: SIMD4<Float>) -> SIMD4<Float> {
        a.columns.0 * v.x + a.columns.1 * v.y + a.columns.2 * v.z + a.columns.3 * v.w
    }
    public static func *= (a: inout simd_float4x4, b: simd_float4x4) { a = a * b }
}
public typealias float4x4 = simd_float4x4
public let matrix_identity_float4x4 = simd_float4x4(diagonal: SIMD4<Float>(1, 1, 1, 1))
public func simd_mul(_ a: simd_float4x4, _ b: simd_float4x4) -> simd_float4x4 { a * b }
public func simd_mul(_ a: simd_float4x4, _ v: SIMD4<Float>) -> SIMD4<Float> { a * v }
public func simd_inverse(_ a: simd_float4x4) -> simd_float4x4 { a.inverse }
public func simd_transpose(_ a: simd_float4x4) -> simd_float4x4 { a.transpose }

public struct simd_quatf: Equatable, Sendable {
    public var vector: SIMD4<Float>
    public init(vector: SIMD4<Float>) { self.vector = vector }
    public init(ix: Float, iy: Float, iz: Float, r: Float) { vector = SIMD4(ix, iy, iz, r) }
    public init(angle: Float, axis: SIMD3<Float>) {
        let n = simd_normalize(axis)
        let s = Foundation.sin(angle / 2)
        vector = SIMD4(n.x * s, n.y * s, n.z * s, Foundation.cos(angle / 2))
    }
    public init(from a: SIMD3<Float>, to b: SIMD3<Float>) {
        let na = simd_normalize(a), nb = simd_normalize(b)
        let c = simd_cross(na, nb)
        let d = simd_dot(na, nb)
        if d < -0.999999 {
            var axis = simd_cross(SIMD3<Float>(1, 0, 0), na)
            if simd_length(axis) < 1e-4 { axis = simd_cross(SIMD3<Float>(0, 1, 0), na) }
            self.init(angle: .pi, axis: axis)
        } else {
            let s = (2 * (1 + d)).squareRoot()
            self.init(vector: SIMD4(c.x / s, c.y / s, c.z / s, s / 2))
        }
    }
    public var imag: SIMD3<Float> { SIMD3(vector.x, vector.y, vector.z) }
    public var real: Float { vector.w }
    public var angle: Float { 2 * atan2(simd_length(imag), real) }
    public var axis: SIMD3<Float> {
        let l = simd_length(imag)
        return l > 0 ? imag / l : SIMD3(1, 0, 0)
    }
    public var conjugate: simd_quatf { simd_quatf(vector: SIMD4(-vector.x, -vector.y, -vector.z, vector.w)) }
    public var normalized: simd_quatf { simd_quatf(vector: vector / simd_length(vector)) }
    public func act(_ v: SIMD3<Float>) -> SIMD3<Float> {
        let u = imag, s = real
        return 2 * simd_dot(u, v) * u + (s * s - simd_dot(u, u)) * v + 2 * s * simd_cross(u, v)
    }
    public static func * (a: simd_quatf, b: simd_quatf) -> simd_quatf {
        let av = a.imag, bv = b.imag
        let v = a.real * bv + b.real * av + simd_cross(av, bv)
        return simd_quatf(vector: SIMD4(v.x, v.y, v.z, a.real * b.real - simd_dot(av, bv)))
    }
}
public func simd_act(_ q: simd_quatf, _ v: SIMD3<Float>) -> SIMD3<Float> { q.act(v) }

// Vector functions, for Float and Double vectors.
public func simd_dot<V: SIMD>(_ a: V, _ b: V) -> V.Scalar where V.Scalar: FloatingPoint { (a * b).sum() }
public func simd_length<V: SIMD>(_ a: V) -> V.Scalar where V.Scalar: FloatingPoint { simd_dot(a, a).squareRoot() }
public func simd_length_squared<V: SIMD>(_ a: V) -> V.Scalar where V.Scalar: FloatingPoint { simd_dot(a, a) }
public func simd_normalize<V: SIMD>(_ a: V) -> V where V.Scalar: FloatingPoint { a / simd_length(a) }
public func simd_distance<V: SIMD>(_ a: V, _ b: V) -> V.Scalar where V.Scalar: FloatingPoint { simd_length(a - b) }
public func simd_distance_squared<V: SIMD>(_ a: V, _ b: V) -> V.Scalar where V.Scalar: FloatingPoint { simd_length_squared(a - b) }
public func simd_min<V: SIMD>(_ a: V, _ b: V) -> V where V.Scalar: Comparable { pointwiseMin(a, b) }
public func simd_max<V: SIMD>(_ a: V, _ b: V) -> V where V.Scalar: Comparable { pointwiseMax(a, b) }
public func simd_clamp<V: SIMD>(_ x: V, _ lo: V, _ hi: V) -> V where V.Scalar: Comparable { pointwiseMin(pointwiseMax(x, lo), hi) }
public func simd_abs<V: SIMD>(_ a: V) -> V where V.Scalar: FloatingPoint { V(a.indices.map { Swift.abs(a[$0]) }) }
public func simd_reduce_min<V: SIMD>(_ a: V) -> V.Scalar where V.Scalar: FloatingPoint { a.min() }
public func simd_reduce_max<V: SIMD>(_ a: V) -> V.Scalar where V.Scalar: FloatingPoint { a.max() }
public func simd_reduce_add<V: SIMD>(_ a: V) -> V.Scalar where V.Scalar: FloatingPoint { a.sum() }
public func simd_mix<V: SIMD>(_ a: V, _ b: V, _ t: V) -> V where V.Scalar: FloatingPoint { a + (b - a) * t }
public func simd_cross(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> SIMD3<Float> {
    SIMD3(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x)
}
public func simd_cross(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> SIMD3<Double> {
    SIMD3(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x)
}
public func simd_precise_normalize<V: SIMD>(_ a: V) -> V where V.Scalar: FloatingPoint { simd_normalize(a) }
// Apple's simd also exports these unprefixed.
public func dot<V: SIMD>(_ a: V, _ b: V) -> V.Scalar where V.Scalar: FloatingPoint { simd_dot(a, b) }
public func length<V: SIMD>(_ a: V) -> V.Scalar where V.Scalar: FloatingPoint { simd_length(a) }
public func normalize<V: SIMD>(_ a: V) -> V where V.Scalar: FloatingPoint { simd_normalize(a) }
public func cross(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> SIMD3<Float> { simd_cross(a, b) }
public func distance<V: SIMD>(_ a: V, _ b: V) -> V.Scalar where V.Scalar: FloatingPoint { simd_distance(a, b) }

// Linux Foundation has no NSData compression; the tests only need it to round-trip.
extension NSData {
    public enum CompressionAlgorithm: Int, Sendable { case lzfse, lz4, lzma, zlib }
    public func compressed(using algorithm: CompressionAlgorithm) throws -> NSData { NSData(data: Data(referencing: self)) }
    public func decompressed(using algorithm: CompressionAlgorithm) throws -> NSData { NSData(data: Data(referencing: self)) }
}
