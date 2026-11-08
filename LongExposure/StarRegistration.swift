import Foundation
import CoreGraphics

/// Match constellations using rigid/similarity geometry rather than scene textures.
enum StarRegistration {
    struct Match {
        var transform: CGAffineTransform
        var pairs: [(Int, Int)]
        var error: CGFloat
    }
    static func align(source: [CGPoint], reference: [CGPoint], size: CGSize) -> CGAffineTransform? {
        guard source.count >= 4, reference.count >= 4 else { return nil }
        let source = Array(source.prefix(30)), reference = Array(reference.prefix(30))
        var best: Match?
        func score(_ t: CGAffineTransform) -> Match? {
            guard abs(atan2(t.b,t.a)) < 0.08, abs(hypot(t.a,t.b)-1) < 0.025,
                  abs(t.tx) < size.width * 0.12, abs(t.ty) < size.height * 0.12 else { return nil }
            var used = Set<Int>(), pairs: [(Int,Int)] = [], total: CGFloat = 0
            for (i,p) in source.enumerated() {
                let point = p.applying(t)
                var nearest: Int?, distance: CGFloat = 2.5 * 2.5
                for (j,r) in reference.enumerated() where !used.contains(j) {
                    let d = (point.x-r.x)*(point.x-r.x)+(point.y-r.y)*(point.y-r.y)
                    if d < distance { nearest = j; distance = d }
                }
                if let j = nearest { used.insert(j); pairs.append((i,j)); total += distance }
            }
            guard pairs.count >= 4, pairs.count * 4 >= min(source.count,reference.count) else { return nil }
            return Match(transform:t,pairs:pairs,error:total/CGFloat(pairs.count))
        }
        for i in 0..<(source.count-1) {
            for j in (i+1)..<source.count {
                let sx = source[j].x-source[i].x, sy = source[j].y-source[i].y
                let length = hypot(sx,sy)
                guard length > 20 else { continue }
                for k in 0..<(reference.count-1) {
                    for l in (k+1)..<reference.count {
                        for swapped in [false,true] {
                            let first = reference[swapped ? l:k], second = reference[swapped ? k:l]
                            let rx = second.x-first.x, ry = second.y-first.y
                            guard abs(hypot(rx,ry)-length) < 2 else { continue }
                            let a = (sx*rx+sy*ry)/(length*length)
                            let b = (sx*ry-sy*rx)/(length*length)
                            let t = CGAffineTransform(a:a,b:b,c:-b,d:a,tx:first.x-a*source[i].x+b*source[i].y,ty:first.y-b*source[i].x-a*source[i].y)
                            if let candidate = score(t), best == nil || candidate.pairs.count > best!.pairs.count || (candidate.pairs.count == best!.pairs.count && candidate.error < best!.error) { best = candidate }
                        }
                    }
                }
            }
        }
        guard let best else { return nil }
        let n = CGFloat(best.pairs.count)
        let sc = best.pairs.reduce(CGPoint.zero) { CGPoint(x:$0.x+source[$1.0].x/n,y:$0.y+source[$1.0].y/n) }
        let rc = best.pairs.reduce(CGPoint.zero) { CGPoint(x:$0.x+reference[$1.1].x/n,y:$0.y+reference[$1.1].y/n) }
        var denominator: CGFloat = 0, dot: CGFloat = 0, cross: CGFloat = 0
        for (i,j) in best.pairs {
            let sx = source[i].x-sc.x, sy = source[i].y-sc.y
            let rx = reference[j].x-rc.x, ry = reference[j].y-rc.y
            denominator += sx*sx+sy*sy; dot += sx*rx+sy*ry; cross += sx*ry-sy*rx
        }
        guard denominator > 1 else { return nil }
        let a = dot/denominator, b = cross/denominator
        let refined = CGAffineTransform(a:a,b:b,c:-b,d:a,tx:rc.x-a*sc.x+b*sc.y,ty:rc.y-b*sc.x-a*sc.y)
        return score(refined)?.transform
    }
}
