import AppKit

enum DinosaurStatusIcon {
  private static let canvas = NSSize(width: 32, height: 18)
  private static let green = NSColor(calibratedRed: 0.24, green: 0.76, blue: 0.28, alpha: 1)
  private static let darkGreen = NSColor(calibratedRed: 0.02, green: 0.28, blue: 0.16, alpha: 1)
  private static let tokenYellow = NSColor(calibratedRed: 1, green: 0.73, blue: 0.05, alpha: 1)

  static func image(mouthOpen: Bool) -> NSImage {
    let image = NSImage(size: canvas, flipped: false) { _ in
      drawSpines()
      if mouthOpen {
        drawOpenHead()
        drawToken()
      } else {
        drawClosedHead()
        drawClosedMouth()
      }
      drawEye()
      return true
    }
    image.isTemplate = false
    return image
  }

  private static func drawSpines() {
    darkGreen.setFill()
    for points in [
      [NSPoint(x: 4, y: 5), NSPoint(x: 0.8, y: 7.5), NSPoint(x: 4.2, y: 9)],
      [NSPoint(x: 4.5, y: 9), NSPoint(x: 1.4, y: 12), NSPoint(x: 6, y: 12.5)],
      [NSPoint(x: 7, y: 13), NSPoint(x: 6.5, y: 17.2), NSPoint(x: 11, y: 14.5)],
    ] {
      let path = NSBezierPath()
      path.move(to: points[0])
      path.line(to: points[1])
      path.line(to: points[2])
      path.close()
      path.fill()
    }
  }

  private static func drawClosedHead() {
    let path = NSBezierPath()
    path.move(to: NSPoint(x: 4, y: 2))
    path.curve(
      to: NSPoint(x: 9, y: 15),
      controlPoint1: NSPoint(x: 3, y: 7),
      controlPoint2: NSPoint(x: 3.5, y: 14)
    )
    path.curve(
      to: NSPoint(x: 16, y: 13),
      controlPoint1: NSPoint(x: 12, y: 15.5),
      controlPoint2: NSPoint(x: 14, y: 14.2)
    )
    path.line(to: NSPoint(x: 24, y: 13))
    path.curve(
      to: NSPoint(x: 27, y: 9),
      controlPoint1: NSPoint(x: 27, y: 13),
      controlPoint2: NSPoint(x: 28.5, y: 11)
    )
    path.curve(
      to: NSPoint(x: 22, y: 5.2),
      controlPoint1: NSPoint(x: 26.7, y: 6.5),
      controlPoint2: NSPoint(x: 24.5, y: 5.3)
    )
    path.line(to: NSPoint(x: 14, y: 5.2))
    path.line(to: NSPoint(x: 12, y: 2))
    path.close()
    fillAndStroke(path)
  }

  private static func drawOpenHead() {
    let upper = NSBezierPath()
    upper.move(to: NSPoint(x: 4, y: 2))
    upper.curve(
      to: NSPoint(x: 9, y: 15),
      controlPoint1: NSPoint(x: 3, y: 7),
      controlPoint2: NSPoint(x: 3.5, y: 14)
    )
    upper.curve(
      to: NSPoint(x: 16, y: 13),
      controlPoint1: NSPoint(x: 12, y: 15.5),
      controlPoint2: NSPoint(x: 14, y: 14.2)
    )
    upper.line(to: NSPoint(x: 24, y: 13))
    upper.curve(
      to: NSPoint(x: 27, y: 10),
      controlPoint1: NSPoint(x: 26.5, y: 13),
      controlPoint2: NSPoint(x: 28, y: 11.7)
    )
    upper.line(to: NSPoint(x: 17, y: 8.3))
    upper.line(to: NSPoint(x: 13, y: 5.4))
    upper.line(to: NSPoint(x: 12, y: 2))
    upper.close()
    fillAndStroke(upper)

    let lowerJaw = NSBezierPath()
    lowerJaw.move(to: NSPoint(x: 13.5, y: 6.3))
    lowerJaw.curve(
      to: NSPoint(x: 25.7, y: 5.2),
      controlPoint1: NSPoint(x: 18, y: 3.2),
      controlPoint2: NSPoint(x: 23, y: 3.5)
    )
    lowerJaw.curve(
      to: NSPoint(x: 17, y: 7.2),
      controlPoint1: NSPoint(x: 27, y: 6),
      controlPoint2: NSPoint(x: 23, y: 7)
    )
    lowerJaw.close()
    fillAndStroke(lowerJaw)
  }

  private static func fillAndStroke(_ path: NSBezierPath) {
    green.setFill()
    path.fill()
    darkGreen.setStroke()
    path.lineWidth = 1
    path.lineJoinStyle = .round
    path.stroke()
  }

  private static func drawEye() {
    NSColor.white.setFill()
    NSBezierPath(ovalIn: NSRect(x: 16.1, y: 9.1, width: 3.8, height: 3.8)).fill()
    darkGreen.setFill()
    NSBezierPath(ovalIn: NSRect(x: 18, y: 10, width: 1.6, height: 1.6)).fill()
  }

  private static func drawClosedMouth() {
    let mouth = NSBezierPath()
    mouth.move(to: NSPoint(x: 20, y: 7.1))
    mouth.curve(
      to: NSPoint(x: 25.1, y: 7.4),
      controlPoint1: NSPoint(x: 22, y: 6.3),
      controlPoint2: NSPoint(x: 24, y: 6.7)
    )
    darkGreen.setStroke()
    mouth.lineWidth = 1.15
    mouth.lineCapStyle = .round
    mouth.stroke()
  }

  private static func drawToken() {
    tokenYellow.setFill()
    NSBezierPath(ovalIn: NSRect(x: 27.2, y: 7, width: 3.3, height: 3.3)).fill()
    NSColor.white.withAlphaComponent(0.8).setFill()
    NSBezierPath(ovalIn: NSRect(x: 28, y: 9, width: 0.8, height: 0.8)).fill()
  }
}
