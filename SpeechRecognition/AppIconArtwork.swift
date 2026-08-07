import CoreGraphics

/// The four selectable app icons.
///
/// `wovenIris` is the primary icon (`AppIcon`); the rest are alternates declared through
/// `ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES`, so their `assetName` is exactly what
/// `UIApplication.setAlternateIconName(_:)` expects.
enum AppIconVariant: String, CaseIterable, Sendable, Identifiable {
  case wovenIris
  case threadAperture
  case braidedBloom
  case wovenIrisInverted

  var id: String { self.rawValue }

  var displayName: String {
    switch self {
    case .wovenIris: "Woven iris"
    case .threadAperture: "Thread aperture"
    case .braidedBloom: "Braided bloom"
    case .wovenIrisInverted: "Woven iris, inverted"
    }
  }

  /// Asset-catalog icon set name.
  var assetName: String {
    switch self {
    case .wovenIris: "AppIcon"
    case .threadAperture: "AppIconThreadAperture"
    case .braidedBloom: "AppIconBraidedBloom"
    case .wovenIrisInverted: "AppIconWovenIrisInverted"
    }
  }

  /// `nil` for the primary icon, matching `UIApplication.alternateIconName` semantics.
  var alternateIconName: String? {
    self == .wovenIris ? nil : self.assetName
  }

  /// The inverse of `alternateIconName`, for reading back the icon UIKit reports as current.
  init(alternateIconName: String?) {
    guard let alternateIconName else {
      self = .wovenIris
      return
    }
    self = Self.allCases.first { $0.assetName == alternateIconName } ?? .wovenIris
  }
}

/// A flat three-tone palette: page, strands, and the center core.
struct AppIconPalette: Equatable, Sendable {
  var background: RGB
  var ink: RGB
  var core: RGB

  struct RGB: Equatable, Sendable {
    var red: Double
    var green: Double
    var blue: Double

    var cgColor: CGColor {
      CGColor(
        colorSpace: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
        components: [self.red, self.green, self.blue, 1]
      ) ?? CGColor(gray: 0, alpha: 1)
    }
  }
}

extension AppIconVariant {
  var palette: AppIconPalette {
    let page = AppIconPalette.RGB(red: 0.937, green: 0.961, blue: 0.980)  // #EFF5FA
    let indigo = AppIconPalette.RGB(red: 0.349, green: 0.408, blue: 0.729)  // #5968BA
    switch self {
    case .wovenIris, .braidedBloom:
      return AppIconPalette(background: page, ink: indigo, core: indigo)
    case .threadAperture:
      return AppIconPalette(
        background: page,
        ink: indigo,
        core: AppIconPalette.RGB(red: 0.557, green: 0.604, blue: 0.831)  // #8E9AD4
      )
    case .wovenIrisInverted:
      return AppIconPalette(
        background: AppIconPalette.RGB(red: 0.192, green: 0.227, blue: 0.486),  // #313A7C
        ink: AppIconPalette.RGB(red: 0.769, green: 0.800, blue: 0.929),  // #C4CCED
        core: AppIconPalette.RGB(red: 0.729, green: 0.769, blue: 0.929)  // #BAC4ED
      )
    }
  }
}

/// Draws the icon family with CoreGraphics alone, so one implementation serves both the
/// asset-catalog PNG export (`Scripts/render-app-icons.sh`) and the live previews in Settings.
/// All geometry is a fraction of `size`, and the context is assumed to use y-down coordinates —
/// the convention of both `GraphicsContext.withCGContext` and the flipped bitmap context the
/// exporter sets up.
enum AppIconArtwork {
  static func draw(_ variant: AppIconVariant, in context: CGContext, size: CGFloat) {
    let palette = variant.palette
    context.setFillColor(palette.background.cgColor)
    context.fill(CGRect(x: 0, y: 0, width: size, height: size))

    let center = CGPoint(x: size / 2, y: size / 2)
    context.setLineCap(.round)
    context.setLineJoin(.round)

    switch variant {
    case .wovenIris, .wovenIrisInverted:
      self.drawRosette(.iris, in: context, center: center, size: size, palette: palette)
    case .braidedBloom:
      self.drawRosette(.bloom, in: context, center: center, size: size, palette: palette)
    case .threadAperture:
      self.drawAperture(in: context, center: center, size: size, palette: palette)
    }
  }

  // MARK: - Woven iris / braided bloom

  /// The rosette is six continuous strands rather than six closed petals: a strand leaves one
  /// petal's outer tip, bows out to form that petal's flank, crosses its own mirror image on the
  /// petal axis, sweeps around the core, and rises again at the tip of the petal `span` positions
  /// along. Every petal is bounded by two strands, which cross at its inner point.
  ///
  /// The iris spans one petal, so its strands meet only at those six points. The bloom spans two,
  /// so each strand also crosses the two strands sweeping alongside it — twelve crossings, enough
  /// for a braid that actually alternates.
  private struct RosetteSpec {
    var strandCount = 6
    var span: Int
    /// Radii as a fraction of the icon's side, angles in degrees.
    var outerRadius: Double
    /// The petal flank, from the outer tip inward: how far the strand stands off the petal axis at
    /// each radius, on the side away from the sweep that follows it.
    var flank: [(radius: Double, degrees: Double)]
    /// Where a strand meets its mirror image on the petal axis.
    var crossingRadius: Double
    /// Closest approach to the core, at the midpoint of the sweep.
    var dipRadius: Double
    var coreRadius: Double
    var lineWidth: Double
    var braided: Bool

    /// Shared by both rosettes, so the braid is unmistakably the same flower as the iris.
    private static let petal: [(radius: Double, degrees: Double)] = [
      (0.340, 6.4), (0.285, 9.2), (0.215, 8.4),
    ]

    static let iris = Self(
      span: 1,
      outerRadius: 0.401,
      flank: Self.petal,
      crossingRadius: 0.158,
      dipRadius: 0.111,
      coreRadius: 0.069,
      lineWidth: 0.023,
      braided: false
    )

    /// The longer sweep passes closer to the core, so the core shrinks to keep the ring clear.
    static let bloom = Self(
      span: 2,
      outerRadius: 0.401,
      flank: Self.petal,
      crossingRadius: 0.158,
      dipRadius: 0.088,
      coreRadius: 0.062,
      lineWidth: 0.023,
      braided: true
    )
  }

  private static func drawRosette(
    _ spec: RosetteSpec,
    in context: CGContext,
    center: CGPoint,
    size: CGFloat,
    palette: AppIconPalette
  ) {
    let lineWidth = size * spec.lineWidth
    let strands = (0..<spec.strandCount).map { index in
      Strand(knots: Self.knots(spec, index: index, center: center, size: size))
    }
    let gaps =
      spec.braided
      ? self.braidGaps(
        strands,
        center: center,
        // Halfway between the two rings of crossings, to tell them apart.
        braidRadius: size * (spec.crossingRadius + spec.dipRadius) / 2,
        lineWidth: lineWidth
      )
      : [[ClosedRange<Double>]](repeating: [], count: strands.count)

    context.setLineWidth(lineWidth)
    context.setStrokeColor(palette.ink.cgColor)
    for (strand, gaps) in zip(strands, gaps) {
      context.addPath(strand.path(skipping: gaps))
      context.strokePath()
    }

    context.setFillColor(palette.core.cgColor)
    let coreRadius = size * spec.coreRadius
    context.fillEllipse(
      in: CGRect(
        x: center.x - coreRadius,
        y: center.y - coreRadius,
        width: coreRadius * 2,
        height: coreRadius * 2
      )
    )
  }

  /// The points a strand is splined through: out at petal `index`, in through that petal's
  /// crossing, around the core, then back out at petal `index + span`. Each flank bows *away* from
  /// the sweep that follows it, so a strand and its mirror image meet the petal axis at an angle —
  /// that is what makes a petal's inner point a crossing rather than a tangency. The knots are
  /// symmetric about the midpoint of the sweep, so neighbouring strands mirror each other exactly
  /// and cross where their radii trade places.
  private static func knots(
    _ spec: RosetteSpec,
    index: Int,
    center: CGPoint,
    size: CGFloat
  ) -> [CGPoint] {
    let step = 360.0 / Double(spec.strandCount)
    let start = Double(index) * step - 90
    let sweep = step * Double(spec.span)
    let end = start + sweep

    // The sweep, sampled every half-petal: radius eases quadratically from each crossing down to
    // the dip at the midpoint.
    let sweepSteps = Int((sweep / (step / 2)).rounded())
    let sweepKnots = (1..<sweepSteps).map { index -> (radius: Double, degrees: Double) in
      let degrees = start + Double(index) * step / 2
      let fromDip = abs(degrees - (start + sweep / 2)) / (sweep / 2)
      return (spec.dipRadius + (spec.crossingRadius - spec.dipRadius) * fromDip * fromDip, degrees)
    }

    let polar: [(radius: Double, degrees: Double)] =
      [(spec.outerRadius, start)]
      + spec.flank.map { (radius: $0.radius, degrees: start - $0.degrees) }
      + [(spec.crossingRadius, start)]
      + sweepKnots
      + [(spec.crossingRadius, end)]
      + spec.flank.reversed().map { (radius: $0.radius, degrees: end + $0.degrees) }
      + [(spec.outerRadius, end)]
    return polar.map { knot in
      let radians = knot.degrees * .pi / 180
      return CGPoint(
        x: center.x + size * knot.radius * cos(radians),
        y: center.y + size * knot.radius * sin(radians)
      )
    }
  }

  /// Turns overlapping strands into a real braid, as the stretch of each strand to leave undrawn
  /// wherever it dives beneath another.
  ///
  /// The over/under order runs in a cycle around the rosette, which no z-ordering of whole strands
  /// can express — layering them is what leaves the crossings looking sliced apart. Interrupting
  /// the under-strand instead settles every crossing independently, and because nothing is
  /// overpainted, two crossings that land close together cannot damage each other.
  private static func braidGaps(
    _ strands: [Strand],
    center: CGPoint,
    braidRadius: CGFloat,
    lineWidth: CGFloat
  ) -> [[ClosedRange<Double>]] {
    let clearance = lineWidth * 1.05
    return strands.enumerated().map { index, strand in
      var gaps: [ClosedRange<Double>] = []
      for (otherIndex, other) in strands.enumerated() where otherIndex != index {
        // Neighbouring strands also share a petal's outer tip. That meeting is the tip, not a
        // crossing, so it must not be cut open.
        let crossings = strand.intersections(
          with: other,
          around: center,
          ignoringEndsWithin: lineWidth * 4
        )
        for crossing in crossings
        where !self.passesOver(crossing, center: center, at: braidRadius) {
          // A shallow crossing hides more of the strand, so widen the gap as the angle closes —
          // up to a point, past which the gap would read as a break rather than a crossing.
          gaps.append(
            strand.interval(around: crossing, clearance: clearance / max(crossing.openness, 0.55))
          )
        }
      }
      return gaps
    }
  }

  /// Whether this strand is the one that passes over at a crossing.
  ///
  /// At the outer crossings — a petal's inner point — the strand climbing back out passes over; at
  /// the inner ones, alongside the core, the strand still heading in does. Since exactly one of any
  /// two crossing strands is climbing, the rule picks a single over-strand without consulting the
  /// other, and because a strand climbs for exactly half its length it alternates over, under,
  /// over, under along its own path: a true braid rather than a pinwheel.
  private static func passesOver(
    _ crossing: Strand.Crossing,
    center: CGPoint,
    at braidRadius: CGFloat
  ) -> Bool {
    let dx = crossing.point.x - center.x
    let dy = crossing.point.y - center.y
    let isOuter = (dx * dx + dy * dy).squareRoot() > braidRadius
    return isOuter == crossing.isClimbing
  }

  // MARK: - Thread aperture

  /// Six blades struck as arcs of one off-center circle, repeated around the icon: the same way a
  /// real iris diaphragm is built, and the reason the shape reads as a shutter caught mid-turn
  /// rather than as a pinwheel of spokes.
  private struct ApertureSpec {
    var bladeCount = 6
    /// The blade circle: how far its center sits from the icon's, and how big it is. It encloses
    /// the icon's center, so a blade drops steeply from the rim and then flattens as it swings
    /// past the core — the arc of an opening shutter, not a spoke.
    var bladeOffset = 0.274
    var bladeRadius = 0.376
    /// Where along that circle the blade starts and stops.
    var outerRadius = 0.417
    var innerRadius = 0.130
    var coreRadius = 0.043
    var lineWidth = 0.023
  }

  private static func drawAperture(
    in context: CGContext,
    center: CGPoint,
    size: CGFloat,
    palette: AppIconPalette
  ) {
    let spec = ApertureSpec()
    context.setLineWidth(size * spec.lineWidth)
    context.setStrokeColor(palette.ink.cgColor)

    /// Where on the blade circle the blade is `radius` from the icon's center, as an angle from
    /// the blade circle's own axis (law of cosines).
    func bladeAngle(at radius: Double) -> Double {
      let cosine =
        (radius * radius - spec.bladeOffset * spec.bladeOffset - spec.bladeRadius
          * spec.bladeRadius) / (2 * spec.bladeOffset * spec.bladeRadius)
      return acos(min(max(cosine, -1), 1))
    }

    let start = bladeAngle(at: spec.outerRadius)
    let end = bladeAngle(at: spec.innerRadius)
    for index in 0..<spec.bladeCount {
      let rotation = Double(index) * 2 * .pi / Double(spec.bladeCount) - .pi / 2
      let path = CGMutablePath()
      path.addArc(
        center: CGPoint(
          x: center.x + size * spec.bladeOffset * cos(rotation),
          y: center.y + size * spec.bladeOffset * sin(rotation)
        ),
        radius: size * spec.bladeRadius,
        startAngle: rotation + start,
        endAngle: rotation + end,
        clockwise: false
      )
      context.addPath(path)
      context.strokePath()
    }

    context.setFillColor(palette.core.cgColor)
    let coreRadius = size * spec.coreRadius
    context.fillEllipse(
      in: CGRect(
        x: center.x - coreRadius,
        y: center.y - coreRadius,
        width: coreRadius * 2,
        height: coreRadius * 2
      )
    )
  }
}

/// A strand splined through its knots with a centripetal Catmull-Rom curve, which holds its shape
/// where the knots bunch up around the crossings instead of looping the way a uniform spline would.
///
/// Positions along a strand are measured in segments: the whole number picks the curve segment and
/// the fraction is the parameter within it, which is what lets a braid gap be cut out of the curve
/// exactly rather than painted over.
private struct Strand {
  let knots: [CGPoint]
  private let segments: [Segment]

  init(knots: [CGPoint]) {
    self.knots = knots
    self.segments = (0..<(knots.count - 1)).map { index in
      Strand.segment(
        knots[max(index - 1, 0)],
        knots[index],
        knots[index + 1],
        knots[min(index + 2, knots.count - 1)]
      )
    }
  }

  func path(skipping gaps: [ClosedRange<Double>] = []) -> CGPath {
    let path = CGMutablePath()
    for span in Strand.spans(upTo: Double(self.segments.count), skipping: gaps) {
      var needsMove = true
      for index in Int(span.lowerBound)...min(Int(span.upperBound), self.segments.count - 1) {
        let from = max(span.lowerBound - Double(index), 0)
        let to = min(span.upperBound - Double(index), 1)
        guard to > from else { continue }
        let piece = self.segments[index].piece(from: CGFloat(from), to: CGFloat(to))
        if needsMove {
          path.move(to: piece.start)
          needsMove = false
        }
        path.addCurve(to: piece.end, control1: piece.control1, control2: piece.control2)
      }
    }
    return path
  }

  /// Flattened curve, for crossing detection, tagged with each point's position along the strand.
  private var polyline: [(point: CGPoint, position: Double)] {
    let steps = 24
    return self.segments.enumerated().flatMap { index, segment in
      (0..<steps).map { step in
        let t = Double(step) / Double(steps)
        return (segment.point(at: CGFloat(t)), Double(index) + t)
      }
    } + [(self.segments[self.segments.count - 1].end, Double(self.segments.count))]
  }

  struct Crossing {
    var point: CGPoint
    var position: Double
    /// Whether this strand's radius is growing as it passes through the crossing.
    var isClimbing: Bool
    /// |sin| of the angle between the two strands: 1 when square, near 0 when they graze.
    var openness: Double
  }

  /// Points where this strand crosses another, skipping anything close to either strand's ends.
  func intersections(
    with other: Strand,
    around center: CGPoint,
    ignoringEndsWithin margin: CGFloat
  ) -> [Crossing] {
    let lhs = self.polyline
    let rhs = other.polyline
    let ends = [lhs.first, lhs.last, rhs.first, rhs.last].compactMap { $0?.point }
    let marginSquared = margin * margin
    var crossings: [Crossing] = []
    for i in 0..<(lhs.count - 1) {
      for j in 0..<(rhs.count - 1) {
        guard
          let hit = Strand.crossing(lhs[i].point, lhs[i + 1].point, rhs[j].point, rhs[j + 1].point)
        else { continue }
        guard ends.allSatisfy({ Strand.distance($0, hit.point) > marginSquared }) else { continue }
        crossings.append(
          Crossing(
            point: hit.point,
            position: lhs[i].position + hit.t * (lhs[i + 1].position - lhs[i].position),
            isClimbing: Strand.distance(center, lhs[i + 1].point)
              > Strand.distance(center, lhs[i].point),
            openness: hit.openness
          )
        )
      }
    }
    return crossings
  }

  /// The stretch of this strand to leave out so `clearance` of it is hidden either side of a
  /// crossing, converted from length into position by the curve's local speed.
  func interval(around crossing: Crossing, clearance: CGFloat) -> ClosedRange<Double> {
    let index = min(Int(crossing.position), self.segments.count - 1)
    let t = crossing.position - Double(index)
    let speed = self.segments[index].speed(at: CGFloat(t))
    let half = speed > 0 ? Double(clearance / speed) : 0.05
    return (crossing.position - half)...(crossing.position + half)
  }

  /// The parts of `0...total` left over once the gaps are removed.
  private static func spans(
    upTo total: Double,
    skipping gaps: [ClosedRange<Double>]
  ) -> [ClosedRange<Double>] {
    let merged = gaps.sorted { $0.lowerBound < $1.lowerBound }
      .reduce(into: [ClosedRange<Double>]()) { merged, gap in
        if let last = merged.last, gap.lowerBound <= last.upperBound {
          merged[merged.count - 1] = last.lowerBound...max(last.upperBound, gap.upperBound)
        } else {
          merged.append(gap)
        }
      }
    var spans: [ClosedRange<Double>] = []
    var cursor = 0.0
    for gap in merged {
      if gap.lowerBound > cursor { spans.append(cursor...min(gap.lowerBound, total)) }
      cursor = max(cursor, gap.upperBound)
      if cursor >= total { break }
    }
    if cursor < total { spans.append(cursor...total) }
    return spans.filter { $0.upperBound > $0.lowerBound }
  }

  private struct Segment {
    var start: CGPoint
    var control1: CGPoint
    var control2: CGPoint
    var end: CGPoint

    func point(at t: CGFloat) -> CGPoint {
      let u = 1 - t
      let a = u * u * u
      let b = 3 * u * u * t
      let c = 3 * u * t * t
      let d = t * t * t
      return CGPoint(
        x: a * self.start.x + b * self.control1.x + c * self.control2.x + d * self.end.x,
        y: a * self.start.y + b * self.control1.y + c * self.control2.y + d * self.end.y
      )
    }

    func derivative(at t: CGFloat) -> CGPoint {
      let u = 1 - t
      let a = 3 * u * u
      let b = 6 * u * t
      let c = 3 * t * t
      return CGPoint(
        x: a * (self.control1.x - self.start.x) + b * (self.control2.x - self.control1.x)
          + c * (self.end.x - self.control2.x),
        y: a * (self.control1.y - self.start.y) + b * (self.control2.y - self.control1.y)
          + c * (self.end.y - self.control2.y)
      )
    }

    func speed(at t: CGFloat) -> CGFloat {
      let derivative = self.derivative(at: t)
      return (derivative.x * derivative.x + derivative.y * derivative.y).squareRoot()
    }

    /// The sub-curve between two parameters, as its own cubic.
    func piece(from start: CGFloat, to end: CGFloat) -> Segment {
      let scale = (end - start) / 3
      let first = self.point(at: start)
      let last = self.point(at: end)
      let firstSlope = self.derivative(at: start)
      let lastSlope = self.derivative(at: end)
      return Segment(
        start: first,
        control1: CGPoint(x: first.x + firstSlope.x * scale, y: first.y + firstSlope.y * scale),
        control2: CGPoint(x: last.x - lastSlope.x * scale, y: last.y - lastSlope.y * scale),
        end: last
      )
    }
  }

  /// Centripetal (alpha = 0.5) Catmull-Rom converted to a cubic Bézier.
  private static func segment(
    _ p0: CGPoint,
    _ p1: CGPoint,
    _ p2: CGPoint,
    _ p3: CGPoint
  ) -> Segment {
    let d1 = max(self.distance(p0, p1).squareRoot(), 1e-6)
    let d2 = max(self.distance(p1, p2).squareRoot(), 1e-6)
    let d3 = max(self.distance(p2, p3).squareRoot(), 1e-6)
    let control1 = CGPoint(
      x: (d1 * d1 * p2.x - d2 * d2 * p0.x + (2 * d1 * d1 + 3 * d1 * d2 + d2 * d2) * p1.x)
        / (3 * d1 * (d1 + d2)),
      y: (d1 * d1 * p2.y - d2 * d2 * p0.y + (2 * d1 * d1 + 3 * d1 * d2 + d2 * d2) * p1.y)
        / (3 * d1 * (d1 + d2))
    )
    let control2 = CGPoint(
      x: (d3 * d3 * p1.x - d2 * d2 * p3.x + (2 * d3 * d3 + 3 * d3 * d2 + d2 * d2) * p2.x)
        / (3 * d3 * (d3 + d2)),
      y: (d3 * d3 * p1.y - d2 * d2 * p3.y + (2 * d3 * d3 + 3 * d3 * d2 + d2 * d2) * p2.y)
        / (3 * d3 * (d3 + d2))
    )
    return Segment(start: p1, control1: control1, control2: control2, end: p2)
  }

  private static func distance(_ lhs: CGPoint, _ rhs: CGPoint) -> CGFloat {
    let dx = rhs.x - lhs.x
    let dy = rhs.y - lhs.y
    return dx * dx + dy * dy
  }

  private static func crossing(
    _ a: CGPoint,
    _ b: CGPoint,
    _ c: CGPoint,
    _ d: CGPoint
  ) -> (point: CGPoint, t: Double, openness: Double)? {
    let r = CGPoint(x: b.x - a.x, y: b.y - a.y)
    let s = CGPoint(x: d.x - c.x, y: d.y - c.y)
    let denominator = r.x * s.y - r.y * s.x
    guard abs(denominator) > 1e-9 else { return nil }
    let offset = CGPoint(x: c.x - a.x, y: c.y - a.y)
    let t = (offset.x * s.y - offset.y * s.x) / denominator
    let u = (offset.x * r.y - offset.y * r.x) / denominator
    guard (0...1).contains(t), (0...1).contains(u) else { return nil }
    let lengths = (self.distance(.zero, r) * self.distance(.zero, s)).squareRoot()
    return (
      point: CGPoint(x: a.x + r.x * t, y: a.y + r.y * t),
      t: Double(t),
      openness: lengths > 0 ? Double(abs(denominator) / lengths) : 1
    )
  }
}
