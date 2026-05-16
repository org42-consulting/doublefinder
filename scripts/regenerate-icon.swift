#!/usr/bin/env swift
// Regenerates the DoubleFinder app icon at every size needed by the .icns bundle,
// the Xcode-style .appiconset, and the in-app About-panel PNG.
//
// Design: the classic "two side-by-side Finder-style faces" silhouette on a sky-to-
// ocean blue squircle. Each face has two narrow capsule "eyes" and a wide single
// smile that spans both faces. Rendered at vector quality for every size, so the
// 16- and 32-pixel variants stay crisp instead of being a downscale of the 1024 PNG.
//
// Run from the repo root:
//   swift scripts/regenerate-icon.swift
//   iconutil --convert icns Icons/AppIcon.iconset -o Sources/DoubleFinder/Resources/DoubleFinder.icns

import AppKit
import CoreGraphics
import Foundation

// MARK: - Palette

struct Palette {
    // Background gradient — sampled directly from the system Finder.app icon at
    // /System/Library/CoreServices/Finder.app/Contents/Resources/Finder.icns. The
    // gradient is pure cyan→azure with R=0 throughout; far more saturated than the
    // muted blues of the older Finder-faces concept art.
    static let bgTop    = CGColor(red: 0.000, green: 0.784, blue: 1.000, alpha: 1.0) // #00C8FF
    static let bgBottom = CGColor(red: 0.000, green: 0.459, blue: 1.000, alpha: 1.0) // #0075FF

    // Face gradient — three stops sampled from the original: near-white at top,
    // pale blue at mid, light sky blue at bottom. This is the key change vs. the
    // previous, too-desaturated version.
    static let faceTop    = CGColor(red: 1.000, green: 1.000, blue: 1.000, alpha: 1.0) // ~#FFFFFF
    static let faceMid    = CGColor(red: 0.831, green: 0.933, blue: 0.992, alpha: 1.0) // #D4EEFD
    static let faceBottom = CGColor(red: 0.620, green: 0.784, blue: 0.980, alpha: 1.0) // #9EC8FA

    // Face border — a saturated pale cyan band sampled from the edges of the
    // original's right face plate. Drawn as an inner stroke so it sits inside the
    // plate rather than expanding its footprint.
    static let faceBorder = CGColor(red: 0.675, green: 0.910, blue: 1.000, alpha: 1.0) // ~#ACE8FF

    // Glassy top-edge highlight on the squircle.
    static let highlight = CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.28)
    static let highlightZero = CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.0)

    // Eyes + smile — saturated dark navy sampled from the original.
    static let ink = CGColor(red: 0.067, green: 0.114, blue: 0.208, alpha: 1.0) // #111D35

    // Soft drop-shadow beneath each face card so the silhouette has depth.
    static let faceShadow = CGColor(red: 0.06, green: 0.18, blue: 0.45, alpha: 0.32)
}

// MARK: - Drawing

func drawIcon(size px: CGFloat) -> NSImage {
    let img = NSImage(size: NSSize(width: px, height: px))
    img.lockFocus()
    defer { img.unlockFocus() }
    guard let ctx = NSGraphicsContext.current?.cgContext else { return img }

    // Canvas: the icon leaves ~7.5% padding around the squircle so the OS can
    // overlay its own shadow/corner mask if it wants to.
    let inset = px * 0.075
    let bg = CGRect(x: inset, y: inset, width: px - inset * 2, height: px - inset * 2)
    let bgCorner = bg.width * 0.225 // macOS squircle-ish
    let bgPath = CGPath(roundedRect: bg, cornerWidth: bgCorner, cornerHeight: bgCorner, transform: nil)
    let space = CGColorSpaceCreateDeviceRGB()

    // 1. Squircle background — diagonal blue gradient.
    ctx.saveGState()
    ctx.addPath(bgPath)
    ctx.clip()
    let bgGrad = CGGradient(colorsSpace: space, colors: [Palette.bgTop, Palette.bgBottom] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(
        bgGrad,
        start: CGPoint(x: bg.midX, y: bg.maxY),
        end: CGPoint(x: bg.midX, y: bg.minY),
        options: []
    )
    // Soft top highlight overlaid on the gradient.
    let hl = CGGradient(colorsSpace: space, colors: [Palette.highlight, Palette.highlightZero] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(
        hl,
        start: CGPoint(x: bg.midX, y: bg.maxY),
        end: CGPoint(x: bg.midX, y: bg.midY + bg.height * 0.15),
        options: []
    )
    ctx.restoreGState()

    // 2. Two rounded-rect face cards.
    let facePad = bg.width * 0.075           // gap to the squircle edge
    let faceGap = bg.width * 0.025           // gap between the two faces
    let faceW = (bg.width - facePad * 2 - faceGap) / 2
    let faceH = bg.height - facePad * 2
    // Match the visual softness of the background squircle. The bg squircle uses
    // ~22.5% of its width, but the face cards are much narrower, so we have to use
    // a much higher proportion of face WIDTH to read as similarly rounded.
    let outerCorner = faceW * 0.45
    // The two corners that face the other card (the inner top + inner bottom) are
    // tightened so the gap between the two cards reads as a clean vertical channel
    // rather than two big arcs nearly meeting.
    let innerCorner = faceW * 0.18
    let leftX = bg.minX + facePad
    let rightX = leftX + faceW + faceGap
    let faceY = bg.minY + facePad
    let leftRect = CGRect(x: leftX, y: faceY, width: faceW, height: faceH)
    let rightRect = CGRect(x: rightX, y: faceY, width: faceW, height: faceH)

    drawFace(in: ctx, rect: leftRect, outer: outerCorner, inner: innerCorner, innerSide: .right, space: space)
    drawFace(in: ctx, rect: rightRect, outer: outerCorner, inner: innerCorner, innerSide: .left, space: space)

    // 3. Eyes — one per face. Narrow vertical capsules.
    let eyeW = faceW * 0.075
    let eyeH = faceH * 0.105
    let eyeY = faceY + faceH * 0.62      // upper portion of face
    let eyeRadius = eyeW / 2

    let eyeXOffsetFromFaceCenter = faceW * 0.0  // perfectly centered horizontally for now
    let leftEye = CGRect(x: leftRect.midX + eyeXOffsetFromFaceCenter - eyeW / 2,
                         y: eyeY,
                         width: eyeW, height: eyeH)
    let rightEye = CGRect(x: rightRect.midX + eyeXOffsetFromFaceCenter - eyeW / 2,
                          y: eyeY,
                          width: eyeW, height: eyeH)

    ctx.setFillColor(Palette.ink)
    ctx.addPath(CGPath(roundedRect: leftEye, cornerWidth: eyeRadius, cornerHeight: eyeRadius, transform: nil))
    ctx.addPath(CGPath(roundedRect: rightEye, cornerWidth: eyeRadius, cornerHeight: eyeRadius, transform: nil))
    ctx.fillPath()

    // 4. Smile — traced directly from the system Finder.app icon's centerline.
    // Sampling code at the bottom of this file produced these points by scanning
    // each column of the 256×256 Finder PNG for the top + bottom of the dark stroke
    // and averaging to find the centerline. Coordinates are canvas-relative with
    // Y measured from the bottom (CG-friendly) so they scale to any icon size.
    // Stroke thickness (3.1% of canvas) is the median measured stroke width.
    let smileSamples: [(x: CGFloat, y: CGFloat)] = [
        (0.2461, 0.3711),
        (0.2734, 0.3594),
        (0.3008, 0.3359),
        (0.3281, 0.3203),
        (0.3555, 0.3047),
        (0.3828, 0.2930),
        (0.4102, 0.2852),
        (0.4375, 0.2812),
        (0.4648, 0.2773),
        (0.4922, 0.2773),
        (0.5195, 0.2773),
        (0.5469, 0.2812),
        (0.5742, 0.2891),
        (0.6016, 0.3008),
        (0.6289, 0.3125),
        (0.6562, 0.3281),
        (0.6836, 0.3477),
        (0.7109, 0.3711),
        (0.7188, 0.3711),
    ]
    let smileWidth = max(px * 0.031, 1.5)

    ctx.saveGState()
    ctx.setLineWidth(smileWidth)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.setStrokeColor(Palette.ink)
    let smile = CGMutablePath()
    smile.move(to: CGPoint(x: smileSamples[0].x * px, y: smileSamples[0].y * px))
    for i in 1..<smileSamples.count {
        let p = smileSamples[i]
        smile.addLine(to: CGPoint(x: p.x * px, y: p.y * px))
    }
    ctx.addPath(smile)
    ctx.strokePath()
    ctx.restoreGState()

    return img
}

enum FaceInnerSide { case left, right }

func drawFace(in ctx: CGContext,
              rect: CGRect,
              outer: CGFloat,
              inner: CGFloat,
              innerSide: FaceInnerSide,
              space: CGColorSpace) {
    // Per-corner radii. The two "inner" corners (facing the other face) are tighter.
    let topLeft:     CGFloat
    let topRight:    CGFloat
    let bottomRight: CGFloat
    let bottomLeft:  CGFloat
    switch innerSide {
    case .right: // left card — inner corners are on its right edge
        topLeft = outer; topRight = inner; bottomRight = inner; bottomLeft = outer
    case .left:  // right card — inner corners are on its left edge
        topLeft = inner; topRight = outer; bottomRight = outer; bottomLeft = inner
    }
    let path = roundedRect(rect, tl: topLeft, tr: topRight, br: bottomRight, bl: bottomLeft)

    // Drop shadow under the face card. Fill with a placeholder so the shadow renders
    // around the silhouette; we'll overwrite with the gradient immediately after.
    ctx.saveGState()
    ctx.setShadow(
        offset: CGSize(width: 0, height: -rect.height * 0.018),
        blur: rect.height * 0.05,
        color: Palette.faceShadow
    )
    ctx.setFillColor(Palette.faceTop)
    ctx.addPath(path)
    ctx.fillPath()
    ctx.restoreGState()

    // Three-stop vertical gradient (white → pale blue → light sky blue) matches
    // the original Finder face's tonal range. Clip while drawing the gradient AND
    // the inner border stroke so neither leaks past the plate's outline.
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let grad = CGGradient(
        colorsSpace: space,
        colors: [Palette.faceTop, Palette.faceMid, Palette.faceBottom] as CFArray,
        locations: [0.0, 0.55, 1.0]
    )!
    ctx.drawLinearGradient(
        grad,
        start: CGPoint(x: rect.midX, y: rect.maxY),
        end: CGPoint(x: rect.midX, y: rect.minY),
        options: []
    )

    // Inner border stroke: a saturated pale-cyan band along the plate edges that
    // gives it a soft outline like the right face in the original DoubleFinder icon.
    // Stroke is centered on the path; with the surrounding clip, only the inner
    // half is rendered — so we double the visual width target.
    ctx.addPath(path)
    ctx.setStrokeColor(Palette.faceBorder)
    ctx.setLineWidth(rect.width * 0.04) // half (~2%) is visible inside
    ctx.strokePath()
    ctx.restoreGState()
}

/// Builds a rounded rectangle with independent corner radii. The coordinate system
/// is CG's natural Y-up (maxY = visual top).
func roundedRect(_ rect: CGRect, tl: CGFloat, tr: CGFloat, br: CGFloat, bl: CGFloat) -> CGPath {
    // Clamp each radius so two adjacent rounds can't overlap.
    let maxR = min(rect.width, rect.height) / 2
    let tlR = min(tl, maxR)
    let trR = min(tr, maxR)
    let brR = min(br, maxR)
    let blR = min(bl, maxR)

    let path = CGMutablePath()
    // Start on the top edge, just right of the top-left corner.
    path.move(to: CGPoint(x: rect.minX + tlR, y: rect.maxY))
    // Top edge → top-right corner
    path.addLine(to: CGPoint(x: rect.maxX - trR, y: rect.maxY))
    path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.maxY),
                tangent2End: CGPoint(x: rect.maxX, y: rect.maxY - trR),
                radius: trR)
    // Right edge → bottom-right corner
    path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + brR))
    path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.minY),
                tangent2End: CGPoint(x: rect.maxX - brR, y: rect.minY),
                radius: brR)
    // Bottom edge → bottom-left corner
    path.addLine(to: CGPoint(x: rect.minX + blR, y: rect.minY))
    path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.minY),
                tangent2End: CGPoint(x: rect.minX, y: rect.minY + blR),
                radius: blR)
    // Left edge → top-left corner
    path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - tlR))
    path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.maxY),
                tangent2End: CGPoint(x: rect.minX + tlR, y: rect.maxY),
                radius: tlR)
    path.closeSubpath()
    return path
}

// MARK: - PNG output

func savePNG(_ image: NSImage, to path: String) throws {
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:])
    else {
        throw NSError(domain: "regenerate-icon", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "PNG encoding failed for \(path)"])
    }
    try png.write(to: URL(fileURLWithPath: path))
    FileHandle.standardOutput.write(Data("  wrote \(path)\n".utf8))
}

// MARK: - Driver

let fm = FileManager.default
let cwd = fm.currentDirectoryPath
print("Generating DoubleFinder icon — cwd: \(cwd)")

// Master PNG used by the About panel.
let master = drawIcon(size: 870)
try savePNG(master, to: "\(cwd)/doublefinder.png")
try savePNG(master, to: "\(cwd)/Sources/DoubleFinder/Resources/doublefinder.png")

// .iconset for iconutil.
let iconsetDir = "\(cwd)/Icons/AppIcon.iconset"
try? fm.createDirectory(atPath: iconsetDir, withIntermediateDirectories: true)
let iconsetSizes: [(String, CGFloat)] = [
    ("icon_16x16",       16),
    ("icon_16x16@2x",    32),
    ("icon_32x32",       32),
    ("icon_32x32@2x",    64),
    ("icon_128x128",    128),
    ("icon_128x128@2x", 256),
    ("icon_256x256",    256),
    ("icon_256x256@2x", 512),
    ("icon_512x512",    512),
    ("icon_512x512@2x", 1024),
]
for (name, sz) in iconsetSizes {
    try savePNG(drawIcon(size: sz), to: "\(iconsetDir)/\(name).png")
}

// .appiconset (Xcode catalog form).
let appiconDir = "\(cwd)/Icons/AppIcon.appiconset"
try? fm.createDirectory(atPath: appiconDir, withIntermediateDirectories: true)
let appiconSizes: [(String, CGFloat)] = [
    ("icon_16x16_1x",     16),
    ("icon_16x16_2x",     32),
    ("icon_32x32_1x",     32),
    ("icon_32x32_2x",     64),
    ("icon_128x128_1x",  128),
    ("icon_128x128_2x",  256),
    ("icon_256x256_1x",  256),
    ("icon_256x256_2x",  512),
    ("icon_512x512_1x",  512),
    ("icon_512x512_2x", 1024),
]
for (name, sz) in appiconSizes {
    try savePNG(drawIcon(size: sz), to: "\(appiconDir)/\(name).png")
}

print("Icon generation done.")
