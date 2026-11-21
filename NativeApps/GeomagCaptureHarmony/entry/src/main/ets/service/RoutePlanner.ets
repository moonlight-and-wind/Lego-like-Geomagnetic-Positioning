import { RoutePoint } from '../model/CaptureModels';

export class RoutePlanner {
  static parse(text: string): RoutePoint[] {
    let trimmed = text.trim();
    if (trimmed.length === 0) {
      return [];
    }
    let tokens = trimmed.split(';');
    let result: RoutePoint[] = [];
    for (let index = 0; index < tokens.length; index++) {
      let coordinates = tokens[index].split(',');
      if (coordinates.length !== 2) {
        return [];
      }
      let x = Number(coordinates[0].trim());
      let y = Number(coordinates[1].trim());
      if (!Number.isFinite(x) || !Number.isFinite(y)) {
        return [];
      }
      result.push(new RoutePoint(x, y, 'free'));
    }
    return result.length >= 2 ? result : [];
  }

  static routeIssue(points: RoutePoint[]): string {
    if (points.length < 2) {
      return '真实路线至少需要两个坐标点。';
    }
    for (let index = 1; index < points.length; index++) {
      let dx = points[index].x - points[index - 1].x;
      let dy = points[index].y - points[index - 1].y;
      if (Math.sqrt(dx * dx + dy * dy) < 0.05) {
        return `路线第 ${index} 与第 ${index + 1} 点距离小于 0.05 m，请删除重复点。`;
      }
    }
    for (let index = 1; index < points.length - 1; index++) {
      let ax = points[index].x - points[index - 1].x;
      let ay = points[index].y - points[index - 1].y;
      let bx = points[index + 1].x - points[index].x;
      let by = points[index + 1].y - points[index].y;
      let cosine = (ax * bx + ay * by) /
        (Math.sqrt(ax * ax + ay * ay) * Math.sqrt(bx * bx + by * by));
      if (cosine < -0.97) {
        return `路线第 ${index + 1} 点形成近 180° 原路折返，请检查坐标顺序。`;
      }
    }
    return '';
  }

  static longSideCrossing(width: number, height: number, spacing: number,
    originX: number, originY: number): RoutePoint[] {
    let safeSpacing = Math.max(0.5, Math.min(spacing, 2.0));
    let route: RoutePoint[] = [];
    if (height >= width) {
      let rowCount = Math.max(1, Math.ceil(height / safeSpacing));
      for (let row = 0; row <= rowCount; row++) {
        let y = originY + Math.min(row * safeSpacing, height);
        if (row % 2 === 0) {
          route.push(new RoutePoint(originX, y, 'long_cross'));
          route.push(new RoutePoint(originX + width, y, 'long_cross'));
        } else {
          route.push(new RoutePoint(originX + width, y, 'long_cross'));
          route.push(new RoutePoint(originX, y, 'long_cross'));
        }
      }
    } else {
      let columnCount = Math.max(1, Math.ceil(width / safeSpacing));
      for (let column = 0; column <= columnCount; column++) {
        let x = originX + Math.min(column * safeSpacing, width);
        if (column % 2 === 0) {
          route.push(new RoutePoint(x, originY, 'long_cross'));
          route.push(new RoutePoint(x, originY + height, 'long_cross'));
        } else {
          route.push(new RoutePoint(x, originY + height, 'long_cross'));
          route.push(new RoutePoint(x, originY, 'long_cross'));
        }
      }
    }
    return RoutePlanner.removeConsecutiveDuplicates(route);
  }

  static serpentine(width: number, height: number, spacing: number, originX: number, originY: number,
    includeCrossScan: boolean = false): RoutePoint[] {
    let route: RoutePoint[] = [];
    let safeSpacing = Math.max(0.2, Math.min(spacing, 1.0));
    let rowCount = Math.max(1, Math.ceil(height / safeSpacing));
    for (let row = 0; row <= rowCount; row++) {
      let y = originY + Math.min(row * safeSpacing, height);
      if (row % 2 === 0) {
        route.push(new RoutePoint(originX, y, 'horizontal'));
        route.push(new RoutePoint(originX + width, y, 'horizontal'));
      } else {
        route.push(new RoutePoint(originX + width, y, 'horizontal'));
        route.push(new RoutePoint(originX, y, 'horizontal'));
      }
    }

    if (!includeCrossScan) {
      return RoutePlanner.removeConsecutiveDuplicates(route);
    }

    // Continue the vertical pass from the corner where the horizontal pass ended.
    // This avoids returning to the origin and then retracing the same boundary line.
    let columnCount = Math.max(1, Math.ceil(width / safeSpacing));
    let lastPoint = route[route.length - 1];
    let startFromRight = Math.abs(lastPoint.x - (originX + width)) < 0.0001;
    for (let step = 0; step <= columnCount; step++) {
      let column = startFromRight ? columnCount - step : step;
      let x = originX + Math.min(column * safeSpacing, width);
      if (step % 2 === 0) {
        route.push(new RoutePoint(x, originY + height, 'vertical'));
        route.push(new RoutePoint(x, originY, 'vertical'));
      } else {
        route.push(new RoutePoint(x, originY, 'vertical'));
        route.push(new RoutePoint(x, originY + height, 'vertical'));
      }
    }
    return RoutePlanner.removeConsecutiveDuplicates(route);
  }

  static reversed(points: RoutePoint[]): RoutePoint[] {
    let result: RoutePoint[] = [];
    for (let index = points.length - 1; index >= 0; index--) {
      let point = points[index];
      result.push(new RoutePoint(point.x, point.y, point.phase));
    }
    return result;
  }

  static initialHeadingDegrees(points: RoutePoint[], fallback: number = 0): number {
    if (points.length < 2) {
      return fallback;
    }
    let first = points[0];
    for (let index = 1; index < points.length; index++) {
      let dx = points[index].x - first.x;
      let dy = points[index].y - first.y;
      if (Math.sqrt(dx * dx + dy * dy) > 0.0001) {
        let degrees = Math.atan2(dy, dx) * 180 / Math.PI;
        return (degrees % 360 + 360) % 360;
      }
    }
    return fallback;
  }

  private static removeConsecutiveDuplicates(points: RoutePoint[]): RoutePoint[] {
    let result: RoutePoint[] = [];
    for (let index = 0; index < points.length; index++) {
      let point = points[index];
      let previous = result.length > 0 ? result[result.length - 1] : undefined;
      if (!previous || Math.abs(previous.x - point.x) > 0.0001 || Math.abs(previous.y - point.y) > 0.0001) {
        result.push(point);
      }
    }
    return result;
  }
}
