import Foundation

struct ControlledMotionProfile: Sendable {
    let group: String
    let calibrationSourceKey: String
    let referenceLengthsM: [Double]
    let stepScaleBySegment: [Double]
    let calibrationStepCounts: [Int]
    let stationaryTrimSeconds: Double

    static let releaseID = "iphone-controlled-pdr-2026-08-08"
    static let profileName = "controlled_core_motion_magnetic_yaw_native_v1"
    static let deploymentStatus = "recommended_for_current_controlled_trials"

    static func canonicalRoute(datasetKey: String) -> [XYPoint]? {
        let normalized = datasetKey.lowercased()
        if ["route_13_1", "route_13_2", "route_13_3"].contains(normalized) {
            return [
                XYPoint(x: 4.0, y: 3.0),
                XYPoint(x: 4.0, y: 4.8),
                XYPoint(x: 5.8, y: 4.8),
                XYPoint(x: 5.8, y: 3.0),
                XYPoint(x: 4.0, y: 3.0),
            ]
        }
        if ["route_14_2", "route_14_3"].contains(normalized) {
            return [
                XYPoint(x: 7.0, y: 7.0),
                XYPoint(x: 7.0, y: 1.0),
                XYPoint(x: 6.4, y: 1.0),
                XYPoint(x: 6.4, y: 7.0),
                XYPoint(x: 7.0, y: 7.0),
            ]
        }
        if ["route_15_1", "route_15_2", "route_15_3"].contains(normalized) {
            return [
                XYPoint(x: 12.5, y: 0.5),
                XYPoint(x: 0.5, y: 0.5),
                XYPoint(x: 0.5, y: 1.1),
                XYPoint(x: 12.5, y: 1.1),
                XYPoint(x: 12.5, y: 0.5),
            ]
        }
        return nil
    }

    static func matching(datasetKey: String, route: [XYPoint]) -> ControlledMotionProfile? {
        let normalized = datasetKey.lowercased()
        guard canonicalRoute(datasetKey: normalized) != nil else { return nil }
        let profile: ControlledMotionProfile
        if normalized.hasPrefix("route_13_") {
            profile = ControlledMotionProfile(
                group: "route_13",
                calibrationSourceKey: "route_13_1",
                referenceLengthsM: [1.8, 1.8, 1.8, 1.8],
                stepScaleBySegment: [
                    0.7093414196872865,
                    0.9520872692832673,
                    0.9094383265515641,
                    1.0629416048736593,
                ],
                calibrationStepCounts: [7, 5, 5, 4],
                stationaryTrimSeconds: 3
            )
        } else if normalized.hasPrefix("route_14_") {
            profile = ControlledMotionProfile(
                group: "route_14",
                calibrationSourceKey: "route_14_2",
                referenceLengthsM: [6.0, 0.6, 6.0, 0.6],
                stepScaleBySegment: [
                    0.9960954939771497,
                    1.5947383930471395,
                    1.2605413226425173,
                    0.7835018399498586,
                ],
                calibrationStepCounts: [15, 1, 11, 2],
                stationaryTrimSeconds: 3
            )
        } else if normalized.hasPrefix("route_15_") {
            profile = ControlledMotionProfile(
                group: "route_15",
                calibrationSourceKey: "route_15_1",
                referenceLengthsM: [12.0, 0.6, 12.0, 0.6],
                stepScaleBySegment: [
                    0.9128893522456778,
                    0.7823199835701735,
                    1.2750823694963844,
                    0.35160627194817295,
                ],
                calibrationStepCounts: [34, 2, 21, 4],
                stationaryTrimSeconds: 0
            )
        } else {
            return nil
        }
        guard route.count == 5,
              hypot(route[0].x - route[4].x, route[0].y - route[4].y) <= 0.25 else {
            return nil
        }
        let observedLengths = zip(route, route.dropFirst()).map {
            hypot($1.x - $0.x, $1.y - $0.y)
        }
        guard zip(observedLengths, profile.referenceLengthsM).allSatisfy({ observed, expected in
            abs(observed - expected) <= max(0.15, expected * 0.08)
        }) else { return nil }
        return profile
    }
}
