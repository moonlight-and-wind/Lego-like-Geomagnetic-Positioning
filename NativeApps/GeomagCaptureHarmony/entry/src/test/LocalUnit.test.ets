import { describe, beforeAll, beforeEach, afterEach, afterAll, it, expect } from '@ohos/hypium';
import { RoutePlanner } from '../main/ets/service/RoutePlanner';

export default function localUnitTest() {
  describe('localUnitTest', () => {
    // Defines a test suite. Two parameters are supported: test suite name and test suite function.
    beforeAll(() => {
      // Presets an action, which is performed only once before all test cases of the test suite start.
      // This API supports only one parameter: preset action function.
    });
    beforeEach(() => {
      // Presets an action, which is performed before each unit test case starts.
      // The number of execution times is the same as the number of test cases defined by **it**.
      // This API supports only one parameter: preset action function.
    });
    afterEach(() => {
      // Presets a clear action, which is performed after each unit test case ends.
      // The number of execution times is the same as the number of test cases defined by **it**.
      // This API supports only one parameter: clear action function.
    });
    afterAll(() => {
      // Presets a clear action, which is performed after all test cases of the test suite end.
      // This API supports only one parameter: clear action function.
    });
    it('crossScanUsesOnlyAxisAlignedSegments', 0, () => {
      let route = RoutePlanner.serpentine(1.8, 6.0, 0.6, 0.5, 0.5, true);
      for (let index = 1; index < route.length; index++) {
        let dx = Math.abs(route[index].x - route[index - 1].x);
        let dy = Math.abs(route[index].y - route[index - 1].y);
        expect(dx < 0.0001 || dy < 0.0001).assertTrue();
      }
    });
    it('reverseRouteSwapsEndpoints', 0, () => {
      let route = RoutePlanner.serpentine(1.8, 6.0, 0.6, 0.5, 0.5, true);
      let reversed = RoutePlanner.reversed(route);
      expect(reversed[0].x).assertEqual(route[route.length - 1].x);
      expect(reversed[0].y).assertEqual(route[route.length - 1].y);
      expect(reversed[reversed.length - 1].x).assertEqual(route[0].x);
      expect(reversed[reversed.length - 1].y).assertEqual(route[0].y);
    });
    it('longSideCrossingChoosesPerpendicularDirection', 0, () => {
      let portrait = RoutePlanner.longSideCrossing(1.8, 6.0, 0.6, 0.5, 0.5);
      expect(portrait[0].y).assertEqual(portrait[1].y);
      expect(Math.abs(Math.abs(portrait[1].x - portrait[0].x) - 1.8) < 0.0001).assertTrue();
      expect(portrait[0].phase).assertEqual('long_cross');

      let landscape = RoutePlanner.longSideCrossing(6.0, 1.8, 0.6, 0.5, 0.5);
      expect(landscape[0].x).assertEqual(landscape[1].x);
      expect(Math.abs(Math.abs(landscape[1].y - landscape[0].y) - 1.8) < 0.0001).assertTrue();
      expect(landscape[0].phase).assertEqual('long_cross');
    });
    it('freeRouteParserAndValidationCatchBacktrack', 0, () => {
      let valid = RoutePlanner.parse('0,0; 0,1; 1,1; 1,0');
      expect(valid.length).assertEqual(4);
      expect(RoutePlanner.routeIssue(valid)).assertEqual('');

      let backtrack = RoutePlanner.parse('0,0; 0.6,1.2; 0,1.2; 1.8,1.2');
      expect(RoutePlanner.routeIssue(backtrack).length > 0).assertTrue();
    });
  });
}
