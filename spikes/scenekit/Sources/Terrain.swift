import Foundation
import SceneKit
import simd
import AppKit

func geometrySource3(_ arr: [SIMD3<Float>], semantic: SCNGeometrySource.Semantic) -> SCNGeometrySource {
    let data = arr.withUnsafeBufferPointer { Data(buffer: $0) }
    return SCNGeometrySource(data: data, semantic: semantic, vectorCount: arr.count, usesFloatComponents: true,
                             componentsPerVector: 3, bytesPerComponent: 4, dataOffset: 0, dataStride: MemoryLayout<SIMD3<Float>>.stride)
}
func geometrySource2(_ arr: [SIMD2<Float>], semantic: SCNGeometrySource.Semantic) -> SCNGeometrySource {
    let data = arr.withUnsafeBufferPointer { Data(buffer: $0) }
    return SCNGeometrySource(data: data, semantic: semantic, vectorCount: arr.count, usesFloatComponents: true,
                             componentsPerVector: 2, bytesPerComponent: 4, dataOffset: 0, dataStride: MemoryLayout<SIMD2<Float>>.stride)
}
func triangleElement(_ idx: [UInt32]) -> SCNGeometryElement {
    let data = idx.withUnsafeBufferPointer { Data(buffer: $0) }
    return SCNGeometryElement(data: data, primitiveType: .triangles, primitiveCount: idx.count / 3, bytesPerIndex: 4)
}

/// Downsampled terrain grid (every `stride`-th DEM cell) that is both rendered and used to drape lines,
/// so draped geometry sits exactly on the rendered triangles.
final class TerrainGrid {
    let dem: DEM
    let stride: Int
    let gRows: Int
    let gCols: Int
    let proj: GeoProjection
    private(set) var heights: [Float]
    private(set) var positions: [SIMD3<Float>]
    var vertexCount: Int { gRows * gCols }
    var triangleCount: Int { (gRows - 1) * (gCols - 1) * 2 }

    init(dem: DEM, stride: Int, proj: GeoProjection) {
        self.dem = dem; self.stride = stride; self.proj = proj
        gRows = (dem.rows - 1) / stride + 1
        gCols = (dem.cols - 1) / stride + 1
        heights = [Float](repeating: 0, count: gRows * gCols)
        positions = [SIMD3<Float>](repeating: .zero, count: gRows * gCols)
        for i in 0..<gRows {
            let r = i * stride
            let lat = dem.lat(forRow: Double(r))
            for j in 0..<gCols {
                let c = j * stride
                let lon = dem.lon(forCol: Double(c))
                let h = dem[r, c]
                let (e, n) = proj.enu(lat: lat, lon: lon)
                heights[i * gCols + j] = h
                positions[i * gCols + j] = SIMD3(Float(e), h, Float(-n))
            }
        }
    }

    /// Height on the rendered triangulated surface (matches the diagonal split used in makeGeometry).
    func surfaceHeight(lat: Double, lon: Double) -> Float {
        let (r, c) = dem.gridCoords(lat: lat, lon: lon)
        let gr = r / Double(stride), gc = c / Double(stride)
        let i = min(max(Int(floor(gr)), 0), gRows - 2), j = min(max(Int(floor(gc)), 0), gCols - 2)
        let fr = Float(min(max(gr - Double(i), 0), 1)), fc = Float(min(max(gc - Double(j), 0), 1))
        let h00 = heights[i * gCols + j], h01 = heights[i * gCols + j + 1]
        let h10 = heights[(i + 1) * gCols + j], h11 = heights[(i + 1) * gCols + j + 1]
        if fr >= fc { return h00 + (h10 - h00) * fr + (h11 - h10) * fc }
        return h00 + (h01 - h00) * fc + (h11 - h01) * fr
    }

    func makeGeometry(textureURL: URL?) -> SCNGeometry {
        var normals = [SIMD3<Float>](repeating: SIMD3(0, 1, 0), count: gRows * gCols)
        var uvs = [SIMD2<Float>](repeating: .zero, count: gRows * gCols)
        for i in 0..<gRows {
            let im = max(i - 1, 0), ip = min(i + 1, gRows - 1)
            for j in 0..<gCols {
                let jm = max(j - 1, 0), jp = min(j + 1, gCols - 1)
                let pw = positions[i * gCols + jm], pe = positions[i * gCols + jp]
                let pn = positions[im * gCols + j], ps = positions[ip * gCols + j]
                let dhdx = (pe.y - pw.y) / max(pe.x - pw.x, 0.001)
                let dhdz = (ps.y - pn.y) / max(ps.z - pn.z, 0.001)
                normals[i * gCols + j] = simd_normalize(SIMD3(-dhdx, 1, -dhdz))
                uvs[i * gCols + j] = SIMD2((Float(j * stride) + 0.5) / Float(dem.cols), (Float(i * stride) + 0.5) / Float(dem.rows))
            }
        }
        var indices = [UInt32](); indices.reserveCapacity((gRows - 1) * (gCols - 1) * 6)
        for i in 0..<(gRows - 1) {
            for j in 0..<(gCols - 1) {
                let v00 = UInt32(i * gCols + j), v01 = v00 + 1
                let v10 = UInt32((i + 1) * gCols + j), v11 = v10 + 1
                indices.append(v00); indices.append(v10); indices.append(v11)
                indices.append(v00); indices.append(v11); indices.append(v01)
            }
        }
        let geo = SCNGeometry(sources: [geometrySource3(positions, semantic: .vertex),
                                        geometrySource3(normals, semantic: .normal),
                                        geometrySource2(uvs, semantic: .texcoord)],
                              elements: [triangleElement(indices)])
        let mat = SCNMaterial()
        mat.lightingModel = .lambert
        if let url = textureURL, let img = NSImage(contentsOf: url) {
            mat.diffuse.contents = img
            mat.diffuse.wrapS = .clamp; mat.diffuse.wrapT = .clamp
            mat.diffuse.mipFilter = .linear
        } else {
            mat.diffuse.contents = NSColor(calibratedRed: 0.55, green: 0.6, blue: 0.5, alpha: 1)
        }
        mat.isDoubleSided = false
        geo.materials = [mat]
        return geo
    }
}

/// Flat horizontal ribbon (triangle list) along a 3D polyline; width in meters.
func ribbonGeometry(points: [SIMD3<Float>], width: Float, color: NSColor) -> SCNGeometry? {
    guard points.count >= 2 else { return nil }
    let hw = width / 2
    let up = SIMD3<Float>(0, 1, 0)
    var verts: [SIMD3<Float>] = []; verts.reserveCapacity(points.count * 2)
    var norms: [SIMD3<Float>] = []; norms.reserveCapacity(points.count * 2)
    var idx: [UInt32] = []; idx.reserveCapacity((points.count - 1) * 6)
    for k in 0..<points.count {
        let p = points[k]
        let prev = points[max(k - 1, 0)], next = points[min(k + 1, points.count - 1)]
        var d = SIMD3<Float>(next.x - prev.x, 0, next.z - prev.z)
        let len = simd_length(d)
        d = len > 1e-6 ? d / len : SIMD3(1, 0, 0)
        let perp = SIMD3<Float>(-d.z, 0, d.x) * hw
        verts.append(p - perp); verts.append(p + perp)
        norms.append(up); norms.append(up)
        if k > 0 {
            let b = UInt32(2 * k)
            idx.append(b - 2); idx.append(b - 1); idx.append(b + 1)
            idx.append(b - 2); idx.append(b + 1); idx.append(b)
        }
    }
    let geo = SCNGeometry(sources: [geometrySource3(verts, semantic: .vertex), geometrySource3(norms, semantic: .normal)],
                          elements: [triangleElement(idx)])
    let mat = SCNMaterial()
    mat.lightingModel = .constant
    mat.diffuse.contents = color
    mat.isDoubleSided = true
    geo.materials = [mat]
    return geo
}
