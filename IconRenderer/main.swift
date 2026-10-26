// `macterm-icon-renderer`: draws the app icon in the colors of the user's
// terminal theme, for the adaptive icon (`AdaptiveIconController`).
//
// It takes one `AdaptiveIconRequest` as JSON in its only argument and writes
// the icon as a PNG on stdout. The request is an argument, not stdin, so the
// app never writes to a pipe that a dead helper closed (an unignored SIGPIPE
// would stop the app). It is the only code in Macterm that calls Apple's private
// IconRendering and CoreUI frameworks — the renderer behind every Liquid Glass
// `.icon` — and it runs in a process of its own for that reason. It links them
// weakly and checks every symbol before the first call (`RequiredSymbols`), so
// a symbol that this macOS lacks ends the run with an exit code that names it.
// A trap inside the framework kills only this process. Either way the app sees
// a failed run and keeps the bundled icon. Nothing here can stop the app.
//
// How the icon is drawn: CoreUI reads the icon's layer stack out of the app's
// own compiled `Assets.car` (the same `AppIcon.icon` that Xcode compiled),
// IconRendering turns it into its `Icon` model, the fills are swapped for the
// request's colors, and IconRendering renders the result with real glass. The
// declarations this compiles against are in PrivateInterfaces/.

import CoreGraphics
import CoreUIPrivate
import Foundation
import IconRendering
import ImageIO
import UniformTypeIdentifiers

func fail(_ code: AdaptiveIconRenderExit, _ message: String) -> Never {
    FileHandle.standardError.write(Data("macterm-icon-renderer: \(message)\n".utf8))
    exit(code.rawValue)
}

/// Where a macOS app icon sits on its canvas, measured from the system's own
/// renders (`NSWorkspace.icon(forFile:)` at 1024 px, any app): the body fills
/// 824 of 1024 px, centered, under a black drop shadow. The helper puts the
/// body there (`opaqueBody`). The shadow values are fitted against the
/// system's render of this same icon: outside the body they match it to 0.11
/// RMSE (of 255).
enum IconCanvas {
    static let bodyFraction = 824.0 / 1024.0
    static let shadowBlur = 32.0 / 1024.0
    static let shadowOffset = 8.0 / 1024.0
    static let shadowAlpha = 0.25
    /// A render whose body spans at least this share of its width is the
    /// body alone, with no grid around it.
    static let fullBleedSpan = 0.97
    /// The direction of the light, in radians. IconRendering's default, 0,
    /// lights the top rims. 2.6 lights the tops and the top-right corners of
    /// the panes, as the design does. A system render of the bundled icon
    /// uses the system's own light.
    static let lightAngle = 2.6
}

func iconColor(_ color: AdaptiveIconRequest.Color) -> IconColor {
    IconColor(red: color.red, green: color.green, blue: color.blue, alpha: 1)
}

guard CommandLine.arguments.count == 2,
      let request = try? JSONDecoder().decode(AdaptiveIconRequest.self, from: Data(CommandLine.arguments[1].utf8)),
      request.pixels > 0, request.pixels <= 4096
else { fail(.badRequest, "the one argument must be an adaptive icon request") }

let missing = RequiredSymbols.missing()
guard missing.isEmpty else {
    fail(.apiMissing, "this macOS lacks \(missing.count) private symbols: \(missing.joined(separator: " "))")
}

let catalog: CUICatalog
do {
    catalog = try CUICatalog(url: URL(fileURLWithPath: request.catalogPath))
} catch {
    fail(.catalogUnreadable, "cannot open \(request.catalogPath): \(error)")
}

let appearanceName = request.appearance == .dark ? "NSAppearanceNameDarkAqua" : "NSAppearanceNameAqua"
guard let stack = catalog.iconLayerStack(
    withName: request.iconName,
    scaleFactor: 1,
    deviceIdiom: 0,
    deviceSubtype: 0,
    displayGamut: 0,
    appearanceName: appearanceName,
    locale: nil
)
else { fail(.iconMissing, "the catalog has no \(appearanceName) layer stack named \(request.iconName)") }

var icon: Icon
do {
    icon = try stack.makeIcon()
} catch {
    fail(.iconMissing, "cannot read the layer stack: \(error)")
}

var layers = icon.layers
guard layers.count == request.layers.count, layers.allSatisfy({ !$0.elements.isEmpty }) else {
    fail(.structureChanged, "the icon has \(layers.count) layer groups, the request names \(request.layers.count)")
}

for (index, color) in request.layers.enumerated() {
    guard let color else { continue }
    var elements = layers[index].elements
    for element in elements.indices {
        elements[element].fill = .solid(iconColor(color))
    }
    layers[index].elements = elements
}

for accent in request.accents ?? [] {
    guard layers.indices.contains(accent.group), layers[accent.group].elements.indices.contains(accent.element) else {
        fail(.structureChanged, "the icon has no layer \(accent.element) in group \(accent.group)")
    }
    // Copy out and back, as above: the interface declares no modify accessors.
    var elements = layers[accent.group].elements
    elements[accent.element].fill = .solid(iconColor(accent.color))
    layers[accent.group].elements = elements
}

icon.layers = layers
icon.chiclet = .gradient(
    start: iconColor(request.backgroundTop),
    end: iconColor(request.backgroundBottom),
    placement: .init(start: CGPoint(x: 0.5, y: 0), end: CGPoint(x: 0.5, y: 1))
)

let canvas = CGFloat(request.pixels)
let body = (canvas * IconCanvas.bodyFraction).rounded()
let style = ICRIconStyle(platform: .main, appearance: request.appearance == .dark ? .dark : .light, renderingMode: .color)
let configuration = RequiredSymbols.isPresent(RequiredSymbols.configurationInits[0])
    ? GlobalConfiguration(lightAngle: IconCanvas.lightAngle)
    : GlobalConfiguration()

/// Renders `icon` at `side` points. The values come in as arguments: top-level
/// variables of `main.swift` are main-actor state, which a function cannot read.
func render(_ icon: Icon, style: ICRIconStyle, configuration: GlobalConfiguration, side: CGFloat) -> CGImage {
    let finalized = FinalizedIcon(
        config: .init(icon: icon, style: style, parametersOverride: nil),
        size: .init(points: CGSize(width: side, height: side), scale: 1)
    )
    guard let rendered = finalized.renderedIcon(with: configuration) else {
        fail(.renderFailed, "IconRendering returned no image")
    }
    return rendered
}

/// The opaque pixels on the middle row of `image` (`row`), or on its middle
/// column, as indexes from the left or from the top. The line is drawn into a
/// context one pixel deep, so the rest of the image is never read.
func opaqueIndexes(of image: CGImage, row: Bool) -> [Int] {
    let width = image.width, height = image.height
    let length = row ? width : height
    var pixels = [UInt8](repeating: 0, count: length * 4)
    guard let context = CGContext(
        data: &pixels,
        width: row ? width : 1,
        height: row ? 1 : height,
        bitsPerComponent: 8,
        bytesPerRow: (row ? width : 1) * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )
    else { fail(.renderFailed, "cannot make a drawing context") }
    // Memory row 0 of a bitmap context is the top of the image.
    context.draw(image, in: CGRect(x: row ? 0 : -width / 2, y: row ? -height / 2 : 0, width: width, height: height))
    return (0 ..< length).filter { pixels[$0 * 4 + 3] > 250 }
}

/// The body of a render: the opaque span of its middle row and column, in
/// the render's pixels, with the origin at the bottom left. A render whose
/// body is not square, or whose middle lines are not mostly opaque (a stray
/// pixel, a hollow render), must never reach the Dock.
func opaqueBody(of image: CGImage) -> CGRect {
    let columns = opaqueIndexes(of: image, row: true)
    let rows = opaqueIndexes(of: image, row: false)
    guard let left = columns.first, let right = columns.last, let top = rows.first, let bottom = rows.last,
          columns.count > image.width / 2, rows.count > image.height / 2,
          abs((right - left) - (bottom - top)) <= 2
    else { fail(.renderFailed, "IconRendering returned an image with no body") }
    return CGRect(x: left, y: image.height - 1 - bottom, width: right - left + 1, height: bottom - top + 1)
}

// What `renderedIcon` draws differs by macOS. On macOS 27 it draws the body
// alone, full-bleed. On macOS 26 it draws the body on the icon grid of its
// canvas (824 of 1024). Neither draws a shadow. 1.33.0 took every render for
// the first, and on macOS 26 its Dock icon was 664 px of 1024. So the helper
// measures the render and places the body itself. The version picks the size
// at which the body draws 1:1, so each macOS renders one time. The measurement
// checks the pick: a macOS that draws the other way gets a second render.
let drawsFullBleed = ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27
var rendered = render(icon, style: style, configuration: configuration, side: drawsFullBleed ? body : canvas)
var renderedBody = opaqueBody(of: rendered)
if (renderedBody.width >= IconCanvas.fullBleedSpan * CGFloat(rendered.width)) != drawsFullBleed {
    rendered = render(icon, style: style, configuration: configuration, side: drawsFullBleed ? canvas : body)
    renderedBody = opaqueBody(of: rendered)
}

guard let colorSpace = CGColorSpace(name: CGColorSpace.displayP3),
      let context = CGContext(
          data: nil,
          width: request.pixels,
          height: request.pixels,
          bitsPerComponent: 8,
          bytesPerRow: 0,
          space: colorSpace,
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      )
else { fail(.renderFailed, "cannot make a drawing context") }
context.setShadow(
    offset: CGSize(width: 0, height: -canvas * IconCanvas.shadowOffset),
    blur: canvas * IconCanvas.shadowBlur,
    color: CGColor(gray: 0, alpha: IconCanvas.shadowAlpha)
)

// Scale the render so that its body is `body` px, and center the body. The
// alpha cut can read the span a pixel short, which must not resample a 1:1
// render.
let scale = abs(renderedBody.width - body) <= 1 ? 1 : body / renderedBody.width
let drawn = CGRect(
    x: (canvas / 2 - renderedBody.midX * scale).rounded(),
    y: (canvas / 2 - renderedBody.midY * scale).rounded(),
    width: (CGFloat(rendered.width) * scale).rounded(),
    height: (CGFloat(rendered.height) * scale).rounded()
)
context.draw(rendered, in: drawn)

let output = NSMutableData()
guard let image = context.makeImage(),
      let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil)
else { fail(.renderFailed, "cannot encode the image") }
CGImageDestinationAddImage(destination, image, nil)
guard CGImageDestinationFinalize(destination) else { fail(.renderFailed, "cannot encode the image") }
FileHandle.standardOutput.write(output as Data)
exit(AdaptiveIconRenderExit.ok.rawValue)
