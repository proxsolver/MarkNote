#!/usr/bin/env swift
// make-icon.swift — 마크노트 앱 아이콘을 코드로 그립니다(Xcode·에셋 카탈로그 없이).
//
//   swift tools/make-icon.swift              → Resources/AppIcon.icns 갱신
//   swift tools/make-icon.swift --check      → .icns 를 읽어 들어 있는 크기를 검증
//   swift tools/make-icon.swift --keep       → 임시 아이컨셋을 지우지 않고 경로 출력(눈으로 볼 때)
//
// 아이콘은 크게 두 부분입니다.
//
// · 종이 타일 — 위가 하얗고 아래로 옅게 가라앉는 스클. 우상단을 접어
//   노란 뒷면이 보이게 합니다. '종이 한 장을 집어 들었다'는 느낌입니다.
// · 마크다운 표지(M↓) — 왼쪽 획에서 아래로, 가운데 V를 타고 올라 오른쪽 획로,
//   그 획이 그대로 화살촉까지 내려갑니다. 본 문단의 강조 색과 같은 앰버로
//   화살표만 따로 칠해 두 색이 짝을 이룹니다.
//
// 격자는 두 번 잰 끝에 캔버스를 가득 채운 스클로 정했습니다. 처음엔 애플
// Notes/TextEdit .icns 처럼 실루엣을 824/1024 로 여백을 두고 그렸지만, 그러면
// 시스템이 아이콘을 '격자에 맞지 않는 것'으로 보고 회색 받침에 얹어 줄여
// 표시합니다(128px 에서 확인). 도형이 캔버스에 붙어야 받침 없이 나옵니다.
// 모서리 비율은 애플 값을 그대로 씁니다 — 런 0.208, 슈퍼타원 지수 4.4.
// 작은 크기로 갈수록 빛·테두리 같은 장식을 덜어내어 16px에서도 M↓이 뭉개지지 않습니다.
import AppKit
import CoreGraphics
import Foundation
import ImageIO

setbuf(stdout, nil)

// MARK: - 격자

let canvas: CGFloat = 1024
let boxSide: CGFloat = 1024
let boxOrigin: CGFloat = 0
let squircleExponent: CGFloat = 4.4
let box = CGRect(x: boxOrigin, y: boxOrigin, width: boxSide, height: boxSide)
/// 접는 폭(1024 기준).
let foldWidth: CGFloat = 196

func srgb(_ r: Int, _ g: Int, _ b: Int, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: a)
}
func alphaOf(_ c: CGColor, _ a: CGFloat) -> CGColor { c.copy(alpha: a)! }

/// 슈퍼타원(연속 모서리) 경로.
func squirclePath(in rect: CGRect, n: CGFloat) -> CGPath {
    let a = rect.width / 2
    let c = CGPoint(x: rect.midX, y: rect.midY)
    var pts: [CGPoint] = []
    for i in 0..<1600 {
        let t = Double(i) / 1600 * 2 * .pi
        let ct = cos(t), st = sin(t)
        pts.append(CGPoint(
            x: c.x + CGFloat((ct >= 0 ? 1 : -1) * Double(a) * pow(abs(ct), 2.0 / Double(n))),
            y: c.y + CGFloat((st >= 0 ? 1 : -1) * Double(a) * pow(abs(st), 2.0 / Double(n)))))
    }
    let p = CGMutablePath()
    p.addLines(between: pts)
    p.closeSubpath()
    return p
}

extension CGContext {
    /// 두 색 이상이면 그라데이션, 하나이면 그 색으로 채웁니다(CGGradient는 단색을 거부합니다).
    func gradient(_ from: CGPoint, _ to: CGPoint, _ colors: [CGColor]) {
        guard colors.count > 1 else {
            setFillColor(colors[0])
            fill(CGRect(x: -canvas, y: -canvas, width: canvas * 3, height: canvas * 3))
            return
        }
        let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                           colors: colors as CFArray, locations: nil)!
        drawLinearGradient(g, start: from, end: to,
                           options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }
}

// MARK: - 종이 타일

/// 접는 선 y = x - k 가 스클 둘레와 만나는 두 점.
/// 선을 따라 바깥(모서리 쪽)에서 안으로 들어오는 경계를 이분법으로 잡습니다.
func creaseEnds(k: CGFloat) -> (CGPoint, CGPoint) {
    let a = boxSide / 2
    let e = Double(squircleExponent)
    func inside(_ x: CGFloat) -> Bool {
        let y = x - k
        return pow(abs(x - box.midX) / a, e) + pow(abs(y - box.midY) / a, e) < 1
    }
    let r = a * pow(0.5, 1 / e)                       // 45° 지점 — 언제나 선 안쪽
    func root(_ outsideX: CGFloat) -> CGFloat {
        var lo = outsideX, hi = box.midX + r
        for _ in 0..<64 {
            let m = (lo + hi) / 2
            if inside(m) { hi = m } else { lo = m }
        }
        return (lo + hi) / 2
    }
    let x1 = root(box.minX - 8)
    let x2 = root(box.maxX + 8)
    return (CGPoint(x: x1, y: x1 - k), CGPoint(x: x2, y: x2 - k))
}

/// 세 꼭지를 반지름 r 로 둥글린 삼각형.
func roundedTriangle(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint, r: CGFloat) -> CGPath {
    let p = CGMutablePath()
    p.move(to: CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2))
    p.addArc(tangent1End: b, tangent2End: c, radius: r)
    p.addArc(tangent1End: c, tangent2End: a, radius: r)
    p.addArc(tangent1End: a, tangent2End: b, radius: r)
    p.closeSubpath()
    return p
}

/// 우상단을 접은 종이 타일. `detail`이 false면 빛·테두리·그림자를 덜어냅니다.
///
/// 접힌 부분은 네 갈래입니다. ① 종이는 스클에서 접는 선 바깥쪽을 뺀 모양으로 칠하고,
/// ② 종이 둘레를 먼저 얹어 테두리가 접힌 날개 위로 새지 않게 한 뒤, ③ 접힌 날개를 그
/// 자리에 얹고, ④ 접는 선과 주름 빛을 날개 안에만 그립니다.
/// 모든 붓질은 스클 안에 클립하므로 잉크가 타일 밖으로 새지 않습니다.
func paintPaperTile(_ ctx: CGContext, detail: Bool) {
    let square = squirclePath(in: box, n: squircleExponent)
    let k = box.maxX - box.minY - foldWidth            // 접는 선: y = x - k
    let (creaseA, creaseB) = creaseEnds(k: k)
    let mid = CGPoint(x: (creaseA.x + creaseB.x) / 2, y: (creaseA.y + creaseB.y) / 2)
    let big = canvas * 2

    // 접는 선의 바깥쪽 반평면을 덮는 거대한 마름모 — 여기서 종이가 잘려나갑니다.
    let gone = CGMutablePath()
    gone.move(to: CGPoint(x: mid.x - big, y: mid.y - big))
    gone.addLine(to: CGPoint(x: mid.x + big, y: mid.y + big))
    gone.addLine(to: CGPoint(x: mid.x + big * 2, y: mid.y))
    gone.addLine(to: CGPoint(x: mid.x, y: mid.y - big * 2))
    gone.closeSubpath()
    let frame = CGRect(x: -big, y: -big, width: canvas + big * 2, height: canvas + big * 2)
    /// 큰 사각형에 마름모를 얹고 even-odd 로 자르면 '반평면 바깥'이 됩니다.
    let half = CGMutablePath()
    half.addRect(frame)
    half.addPath(gone)

    // 접힌 날개 — 접기 전 모서리 (maxX, minY) 가 접는 선에 비쳐 내려온 자리.
    // 스클은 모서리가 둥글어 실제로 잘려나가는 조각은 얇은 초승달이지만,
    // 아이콘에서 '접혔다'고 읽히는 것은 삼각형입니다. 그래서 삼각형을 그리고
    // 꼭지 세 곳만 살짝 둥글립니다.
    let flapTip = CGPoint(x: box.minY + k, y: box.maxX - k)   // (maxX, minY) 의 대칭점
    let flap = roundedTriangle(creaseA, creaseB, flapTip, r: 12)

    // ① 본문 종이
    ctx.saveGState()
    ctx.addPath(half)
    ctx.clip(using: .evenOdd)
    ctx.addPath(square)
    ctx.clip()
    ctx.gradient(CGPoint(x: box.minX + boxSide * 0.18, y: box.minY),
                 CGPoint(x: box.maxX - boxSide * 0.18, y: box.maxY),
                 [srgb(255, 255, 255), srgb(217, 225, 238)])
    if detail {
        ctx.gradient(CGPoint(x: box.midX, y: box.minY), CGPoint(x: box.midX, y: box.midY),
                     [alphaOf(srgb(255, 255, 255), 0.92), alphaOf(srgb(255, 255, 255), 0)])
        ctx.gradient(CGPoint(x: box.midX, y: box.midY), CGPoint(x: box.midX, y: box.maxY),
                     [alphaOf(srgb(0, 0, 0), 0), alphaOf(srgb(0, 0, 0), 0.05)])
    }
    ctx.restoreGState()

    // ② 종이 둘레 — 접힌 날개를 얹기 전에 그려, 테두리가 날개 위로 새지 않게 합니다.
    ctx.saveGState()
    ctx.addPath(half)
    ctx.clip(using: .evenOdd)
    ctx.addPath(square)
    ctx.clip()
    if detail {
        ctx.addPath(square)
        ctx.setLineWidth(3)
        ctx.setStrokeColor(srgb(255, 255, 255, 0.95))
        ctx.strokePath()
    }
    ctx.addPath(square)
    ctx.setLineWidth(1)
    ctx.setStrokeColor(srgb(24, 34, 60, 0.16))
    ctx.strokePath()
    ctx.restoreGState()

    // ③ 접힌 날개 — 종이에 그림자를 하나 떨어뜨리고, 주름에서 멀수록 밝게 칠합니다.
    ctx.saveGState()
    ctx.addPath(half)
    ctx.clip(using: .evenOdd)
    ctx.addPath(square)
    ctx.clip()
    if detail {
        ctx.setShadow(offset: CGSize(width: -7, height: 9), blur: 18, color: srgb(20, 26, 48, 0.20))
    }
    ctx.addPath(flap)
    ctx.setFillColor(srgb(228, 156, 34))
    ctx.fillPath()
    ctx.setShadow(offset: .zero, blur: 0, color: nil)
    ctx.addPath(flap)
    ctx.clip()
    ctx.gradient(flapTip, mid, [srgb(255, 203, 112), srgb(212, 131, 12)])

    // ④ 접는 선과 주름 빛 — 날개 안에만 그리므로 모서리 밖으로 삐져나가지 않습니다.
    ctx.setLineCap(.round)
    ctx.setLineWidth(2)
    ctx.setStrokeColor(srgb(120, 76, 8, 0.40))
    ctx.move(to: creaseA)
    ctx.addLine(to: creaseB)
    ctx.strokePath()
    if detail {
        ctx.setLineWidth(3)
        ctx.setStrokeColor(srgb(255, 255, 255, 0.50))
        ctx.move(to: CGPoint(x: creaseA.x - 3, y: creaseA.y + 3))
        ctx.addLine(to: CGPoint(x: creaseB.x - 3, y: creaseB.y + 3))
        ctx.strokePath()
    }
    ctx.restoreGState()
}

// MARK: - 마크다운 표지

/// M↓ 표지 하나. (x, y)는 왼쪽 위, `total`은 화살촉 끝까지의 높이.
struct MarkdownMark {
    var center: CGPoint
    var total: CGFloat
    var width: CGFloat
    var stem: CGFloat

    var x: CGFloat { center.x - width / 2 }
    var y: CGFloat { center.y - total / 2 }
    var body: CGFloat { total * 0.67 }
    var drop: CGFloat { total * 0.175 }
    var head: CGFloat { total * 0.155 }
    var spread: CGFloat { stem * 1.22 }
    var baseline: CGFloat { y + body }
    var shaftX: CGFloat { x + width - stem / 2 }
    var bbox: CGRect {
        CGRect(x: x - stem / 2, y: y - stem / 2, width: width + stem, height: total + stem)
    }

    /// 획을 채움 경로로 풀고(라운드 조인·캡 보존) 화살촉과 합칩니다.
    func outline() -> CGPath {
        let half = stem / 2
        let bodyPath = CGMutablePath()
        bodyPath.move(to: CGPoint(x: x + half, y: y + body))
        bodyPath.addLine(to: CGPoint(x: x + half, y: y))
        bodyPath.addLine(to: CGPoint(x: x + width / 2, y: y + body))
        bodyPath.addLine(to: CGPoint(x: x + width - half, y: y))
        bodyPath.addLine(to: CGPoint(x: x + width - half, y: y + body + drop))
        let out = CGMutablePath()
        out.addPath(bodyPath.copy(strokingWithWidth: stem, lineCap: .round,
                                  lineJoin: .round, miterLimit: 10))
        let tip = CGMutablePath()
        tip.move(to: CGPoint(x: shaftX - spread, y: baseline + drop))
        tip.addLine(to: CGPoint(x: shaftX, y: baseline + drop + head))
        tip.addLine(to: CGPoint(x: shaftX + spread, y: baseline + drop))
        tip.closeSubpath()
        out.addPath(tip)
        return out
    }
}

/// 표지를 그립니다. `arrow`을 주면 기준선 아래(화살표)만 그 색으로 칠합니다.
func paintMark(_ ctx: CGContext, _ m: MarkdownMark, body: [CGColor], arrow: [CGColor]?,
               shadow: CGColor?) {
    let outline = m.outline()
    let bbox = m.bbox
    if let shadow {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 10), blur: 16, color: shadow)
        ctx.addPath(outline)
        ctx.setFillColor(body.last!)
        ctx.fillPath()
        ctx.restoreGState()
    }
    ctx.saveGState()
    ctx.addPath(outline)
    ctx.clip()
    ctx.gradient(CGPoint(x: bbox.midX, y: bbox.minY), CGPoint(x: bbox.midX, y: bbox.maxY), body)
    if let arrow {
        let region = CGRect(x: m.shaftX - m.spread - 2, y: m.baseline + 1,
                            width: m.spread * 2 + 4, height: canvas)
        ctx.addPath(CGPath(rect: region, transform: nil))
        ctx.clip()
        ctx.gradient(CGPoint(x: bbox.midX, y: m.baseline), CGPoint(x: bbox.midX, y: bbox.maxY), arrow)
    }
    ctx.restoreGState()
}

/// 한 장을 그립니다. 접힌 모서리 때문에 표지는 왼쪽 아래로 살짝 밀어 여백을 맞춥니다.
func drawIcon(_ ctx: CGContext, pixel: CGFloat) {
    let detail = pixel >= 64
    paintPaperTile(ctx, detail: detail)
    let u = boxSide / 824
    let nudge: CGFloat = 24 * u
    let thick: CGFloat = (pixel <= 32 ? 66 : 60) * u
    let m = MarkdownMark(center: CGPoint(x: box.midX - nudge, y: box.midY + nudge),
                         total: 566 * u, width: 380 * u, stem: thick)
    paintMark(ctx, m,
              body: [srgb(74, 114, 226), srgb(22, 42, 112)],
              arrow: detail ? [srgb(250, 188, 74), srgb(214, 132, 12)]
                            : [srgb(240, 166, 48), srgb(224, 142, 22)],
              shadow: detail ? srgb(28, 46, 96, 0.11) : nil)
}

func renderPNG(_ pixel: Int, to url: URL) {
    guard let ctx = CGContext(data: nil, width: pixel, height: pixel, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        fatalError("icon: 비트맵 컨텍스트를 만들 수 없습니다 (\(pixel))")
    }
    let k = CGFloat(pixel) / canvas
    ctx.scaleBy(x: k, y: k)
    // 코어 그래픽스는 y가 위쪽, 설계는 아래쪽으로 읽습니다.
    ctx.translateBy(x: 0, y: canvas)
    ctx.scaleBy(x: 1, y: -1)
    drawIcon(ctx, pixel: CGFloat(pixel))
    guard let img = ctx.makeImage(),
          let data = NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:]) else {
        fatalError("icon: PNG 인코딩에 실패했습니다 (\(pixel))")
    }
    try! data.write(to: url)
}

// MARK: - 아이컨셋 → .icns

/// iconutil이 요구하는 이름과 실제 픽셀.
let iconSizes: [(name: String, pixel: Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]

/// 저장소 루트 — 이 스크립트(`tools/make-icon.swift`)의 부모. 어디서 실행하든 같은 자리를 가리킵니다.
let repo = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()   // tools/
    .deletingLastPathComponent()   // MarkNote/
let output = repo.appendingPathComponent("Resources/AppIcon.icns")
let check = CommandLine.arguments.contains("--check")

if check {
    // .icns 를 바로 읽어 실제 들어 있는 크기를 세어 봅니다.
    // 이 시스템의 iconutil 에는 --extract(-x) 가 없으므로 아이컨셋을 되돌려 받지 않고
    // 이미지 소스로 각 레파의 픽셀을 읽습니다.
    guard FileManager.default.fileExists(atPath: output.path) else {
        print("✗ \(output.path) 가 없습니다. swift tools/make-icon.swift 로 만드세요."); exit(1)
    }
    guard let src = CGImageSourceCreateWithURL(output as CFURL, nil) else {
        print("✗ \(output.path) 을 이미지 소스로 열 수 없습니다."); exit(1)
    }
    let count = CGImageSourceGetCount(src)
    var found: Set<Int> = []
    for i in 0..<count {
        guard let props = CGImageSourceCopyPropertiesAtIndex(src, i, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int else {
            print("✗ 레파 \(i): 속성 없음"); continue
        }
        found.insert(w)
        print("✓ 레파 \(i): \(w)x\(h)")
    }
    // 16·32·64·128·256·512·1024 — @2x 쌍이 한 번씩은 들어야 하는 크기입니다.
    let needed: Set<Int> = [16, 32, 64, 128, 256, 512, 1024]
    let missing = needed.subtracting(found).sorted()
    guard missing.isEmpty else {
        print("✗ 없는 크기: \(missing.map(String.init).joined(separator: ", "))"); exit(1)
    }
    let bytes = (try? Data(contentsOf: output).count) ?? 0
    print("✓ \(output.lastPathComponent): \(count)개 레파, \(bytes / 1024) KB — 필요 크기 모두 포함")
    exit(0)
}

let iconset = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("marknote-iconset.iconset")
let fm = FileManager.default
try? fm.removeItem(at: iconset)
try! fm.createDirectory(at: iconset, withIntermediateDirectories: true)
try! fm.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
for entry in iconSizes {
    renderPNG(entry.pixel, to: iconset.appendingPathComponent(entry.name))
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try! iconutil.run()
iconutil.waitUntilExit()
if CommandLine.arguments.contains("--keep") {
    print("· 아이컨셋 보관: \(iconset.path)")
} else {
    try? fm.removeItem(at: iconset)
}
guard iconutil.terminationStatus == 0 else {
    print("✗ iconutil -c icns 실패(\(iconutil.terminationStatus)) — --keep 으로 아이컨셋을 남기고 손으로 돌려보세요.")
    exit(1)
}
let bytes = (try? Data(contentsOf: output).count) ?? 0
print("✓ \(output.path) (\(bytes / 1024) KB, \(iconSizes.count) 크기)")
