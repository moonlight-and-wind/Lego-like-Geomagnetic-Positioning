import { sensor } from '@kit.SensorServiceKit';
import {
  CaptureConfig,
  CaptureCounts,
  CaptureSnapshot,
  MotionSample,
  RoutePoint,
  SpatialEvent,
  VectorSample
} from '../model/CaptureModels';

export class MotionRecorder {
  isRecording: boolean = false;
  isPaused: boolean = false;
  statusMessage: string = '准备采集';
  elapsedSeconds: number = 0;
  magneticMagnitude: number = 0;
  rollDegrees: number = 0;
  pitchDegrees: number = 0;
  yawDegrees: number = 0;
  globalHeadingDegrees: number = 0;
  counts: CaptureCounts = new CaptureCounts();
  nextRouteIndex: number = 0;
  skippedRoutePoints: number = 0;

  private config: CaptureConfig = new CaptureConfig();
  private startedAt: Date = new Date();
  private stoppedAt: Date = new Date();
  private startWallMilliseconds: number = 0;
  private firstSensorTimestamp: number = -1;
  private initialDeviceYaw: number = 0;
  private hasInitialDeviceYaw: boolean = false;
  private timerId: number = -1;

  private accelerometer: VectorSample[] = [];
  private gyroscope: VectorSample[] = [];
  private magnetometer: VectorSample[] = [];
  private magnetometerRaw: VectorSample[] = [];
  private deviceMotion: MotionSample[] = [];
  private spatialEvents: SpatialEvent[] = [];

  private latestGravity: number[] = [0, 0, 0];
  private latestLinearAcceleration: number[] = [0, 0, 0];
  private latestGyroscope: number[] = [0, 0, 0];
  private latestMagneticField: number[] = [0, 0, 0];
  private latestMagneticAccuracy: number = -1;

  start(config: CaptureConfig): void {
    if (this.isRecording) {
      return;
    }
    this.config = config;
    this.startedAt = new Date();
    this.stoppedAt = this.startedAt;
    this.startWallMilliseconds = Date.now();
    this.firstSensorTimestamp = -1;
    this.initialDeviceYaw = 0;
    this.hasInitialDeviceYaw = false;
    this.elapsedSeconds = 0;
    this.magneticMagnitude = 0;
    this.rollDegrees = 0;
    this.pitchDegrees = 0;
    this.yawDegrees = 0;
    this.globalHeadingDegrees = config.initialHeadingDegrees;
    this.nextRouteIndex = config.route.length > 0 ? 1 : 0;
    this.skippedRoutePoints = 0;
    this.counts = new CaptureCounts();
    this.accelerometer = [];
    this.gyroscope = [];
    this.magnetometer = [];
    this.magnetometerRaw = [];
    this.deviceMotion = [];
    this.spatialEvents = [];
    this.latestGravity = [0, 0, 0];
    this.latestLinearAcceleration = [0, 0, 0];
    this.latestGyroscope = [0, 0, 0];
    this.latestMagneticField = [0, 0, 0];
    this.latestMagneticAccuracy = -1;

    this.spatialEvents.push(new SpatialEvent(0, 'anchor', 'start', config.startX, config.startY,
      config.initialHeadingDegrees, undefined));
    this.isRecording = true;
    this.isPaused = false;
    this.statusMessage = '正在采集 · 请保持手机正面朝上、前端朝前';
    if (!this.subscribeSensors()) {
      return;
    }
    this.timerId = setInterval(() => {
      this.elapsedSeconds = this.currentTime();
    }, 200);
  }

  stop(reason: string = 'stop'): CaptureSnapshot {
    if (!this.isRecording) {
      return this.snapshot();
    }
    this.elapsedSeconds = this.currentTime();
    this.spatialEvents.push(new SpatialEvent(this.elapsedSeconds, 'recording_stop', reason, undefined, undefined,
      this.currentHeading(), this.hasInitialDeviceYaw ? this.yawDegrees : undefined));
    this.isRecording = false;
    this.isPaused = false;
    this.unsubscribeSensors();
    if (this.timerId >= 0) {
      clearInterval(this.timerId);
      this.timerId = -1;
    }
    this.stoppedAt = new Date();
    this.statusMessage = '采集完成 · 可以导出';
    return this.snapshot();
  }

  togglePause(): void {
    if (!this.isRecording) {
      return;
    }
    this.isPaused = !this.isPaused;
    let type = this.isPaused ? 'pause' : 'resume';
    this.spatialEvents.push(new SpatialEvent(this.currentTime(), type, type, undefined, undefined,
      this.currentHeading(), this.hasInitialDeviceYaw ? this.yawDegrees : undefined));
    this.statusMessage = this.isPaused
      ? '建图已暂停 · 可绕过障碍物或移动到下一扫描线起点'
      : '建图已恢复 · 继续沿扫描线采集';
  }

  recordNextRoutePoint(): boolean {
    if (!this.isRecording || this.isPaused || this.nextRouteIndex >= this.config.route.length) {
      return false;
    }
    let point = this.config.route[this.nextRouteIndex];
    this.spatialEvents.push(new SpatialEvent(this.currentTime(), 'anchor', `route-point-${this.nextRouteIndex}`,
      point.x, point.y, this.currentHeading(), this.hasInitialDeviceYaw ? this.yawDegrees : undefined));
    this.nextRouteIndex += 1;
    this.statusMessage = this.nextRouteIndex < this.config.route.length
      ? '锚点已记录 · 继续前往下一点'
      : '全部路线点已完成 · 可停止采集';
    return true;
  }

  recordNextRoutePointAndTurn(): boolean {
    if (!this.isRecording || this.isPaused || this.nextRouteIndex >= this.config.route.length) {
      return false;
    }
    if (!this.phoneIsFlat()) {
      this.statusMessage = '手机倾斜超过 15° · 请先保持正面朝上再确认点位';
      return false;
    }
    let pointIndex = this.nextRouteIndex;
    let point = this.config.route[pointIndex];
    let shouldMarkTurn = this.routeTurnsAt(pointIndex);
    let time = this.currentTime();
    this.spatialEvents.push(new SpatialEvent(time, 'anchor', `route-point-${pointIndex}`,
      point.x, point.y, this.currentHeading(), this.hasInitialDeviceYaw ? this.yawDegrees : undefined));
    this.nextRouteIndex += 1;
    if (shouldMarkTurn) {
      this.spatialEvents.push(new SpatialEvent(time, 'turn', `route-turn-${pointIndex}`, undefined, undefined,
        this.currentHeading(), this.hasInitialDeviceYaw ? this.yawDegrees : undefined));
      this.statusMessage = '已同时记录路线锚点和转弯起点 · 现在可以转向';
    } else if (this.nextRouteIndex < this.config.route.length) {
      this.statusMessage = '路线锚点已记录 · 保持方向继续行走';
    } else {
      this.statusMessage = '终点锚点已记录 · 全部路线点已完成';
    }
    return true;
  }

  nextRoutePointRequiresTurn(): boolean {
    return this.routeTurnsAt(this.nextRouteIndex);
  }

  skipNextRoutePoint(): boolean {
    if (!this.isRecording || !this.isPaused || this.nextRouteIndex >= this.config.route.length) {
      return false;
    }
    let point = this.config.route[this.nextRouteIndex];
    this.spatialEvents.push(new SpatialEvent(this.currentTime(), 'anchor_skipped',
      `route-point-${this.nextRouteIndex}`, point.x, point.y, this.currentHeading(),
      this.hasInitialDeviceYaw ? this.yawDegrees : undefined));
    this.nextRouteIndex += 1;
    this.skippedRoutePoints += 1;
    this.statusMessage = '已跳过不可达点 · 绕行后在已知坐标处恢复并记录锚点';
    return true;
  }

  recordManualAnchor(x: number, y: number, label: string = 'manual-anchor'): void {
    if (!this.isRecording || this.isPaused) {
      return;
    }
    this.spatialEvents.push(new SpatialEvent(this.currentTime(), 'anchor', label, x, y,
      this.currentHeading(), this.hasInitialDeviceYaw ? this.yawDegrees : undefined));
    this.statusMessage = `已记录锚点 (${x.toFixed(2)}, ${y.toFixed(2)})`;
  }

  recordTurn(label: string = 'turn'): void {
    if (!this.isRecording || this.isPaused) {
      return;
    }
    if (!this.phoneIsFlat()) {
      this.statusMessage = '手机倾斜超过 15° · 请保持正面朝上再标记转弯';
      return;
    }
    this.spatialEvents.push(new SpatialEvent(this.currentTime(), 'turn', label, undefined, undefined,
      this.currentHeading(), this.hasInitialDeviceYaw ? this.yawDegrees : undefined));
    this.statusMessage = '已记录转弯起点 · 现在可以转向';
  }

  undoLastRouteEvent(): boolean {
    if (!this.isRecording || this.spatialEvents.length <= 1) {
      return false;
    }
    for (let index = this.spatialEvents.length - 1; index >= 1; index--) {
      let event = this.spatialEvents[index];
      if (event.label.startsWith('route-point-')) {
        this.spatialEvents.splice(index, 1);
        this.nextRouteIndex = Math.max(1, this.nextRouteIndex - 1);
        if (event.type === 'anchor_skipped') {
          this.skippedRoutePoints = Math.max(0, this.skippedRoutePoints - 1);
        }
        this.statusMessage = '已撤销上一个路线点';
        return true;
      }
    }
    return false;
  }

  routeProgressText(): string {
    if (this.config.route.length === 0) {
      return '自由采集';
    }
    return `${Math.min(this.nextRouteIndex, this.config.route.length)}/${this.config.route.length}`;
  }

  routePhaseText(): string {
    if (this.config.route.length === 0) {
      return '自由采集';
    }
    let index = Math.min(this.nextRouteIndex, this.config.route.length - 1);
    let phase = this.config.route[index].phase;
    if (phase === 'long_cross') {
      return '横穿长边补扫';
    }
    if (phase === 'free') {
      return '自由规划路线';
    }
    return phase === 'vertical' ? '纵向交叉' : '横向蛇形';
  }

  nextRoutePointText(): string {
    if (this.nextRouteIndex >= this.config.route.length) {
      return '路线点已全部完成';
    }
    let point: RoutePoint = this.config.route[this.nextRouteIndex];
    return `下一点 (${point.x.toFixed(2)}, ${point.y.toFixed(2)}) m`;
  }

  phoneIsFlat(): boolean {
    return Math.abs(this.rollDegrees) <= 15 && Math.abs(this.pitchDegrees) <= 15;
  }

  private routeTurnsAt(index: number): boolean {
    if (index <= 0 || index >= this.config.route.length - 1) {
      return false;
    }
    let previous = this.config.route[index - 1];
    let point = this.config.route[index];
    let next = this.config.route[index + 1];
    let ax = point.x - previous.x;
    let ay = point.y - previous.y;
    let bx = next.x - point.x;
    let by = next.y - point.y;
    let cosine = Math.max(-1, Math.min(1, (ax * bx + ay * by) /
      (Math.sqrt(ax * ax + ay * ay) * Math.sqrt(bx * bx + by * by))));
    return Math.acos(cosine) * 180 / Math.PI >= 15;
  }

  snapshot(): CaptureSnapshot {
    return new CaptureSnapshot(this.config, this.startedAt, this.stoppedAt, this.accelerometer.slice(),
      this.gyroscope.slice(), this.magnetometer.slice(), this.magnetometerRaw.slice(),
      this.deviceMotion.slice(), this.spatialEvents.slice());
  }

  private subscribeSensors(): boolean {
    let options: sensor.Options = { interval: 10000000 };
    try {
      sensor.on(sensor.SensorId.ACCELEROMETER, (data: sensor.AccelerometerResponse) => {
        if (!this.isRecording || this.isPaused) {
          return;
        }
        this.accelerometer.push(new VectorSample(this.sensorTime(data.timestamp), data.x, data.y, data.z,
          Number(data.accuracy)));
        this.counts.accelerometer = this.accelerometer.length;
      }, options);
      sensor.on(sensor.SensorId.GYROSCOPE, (data: sensor.GyroscopeResponse) => {
        if (!this.isRecording || this.isPaused) {
          return;
        }
        this.latestGyroscope = [data.x, data.y, data.z];
        this.gyroscope.push(new VectorSample(this.sensorTime(data.timestamp), data.x, data.y, data.z,
          Number(data.accuracy)));
        this.counts.gyroscope = this.gyroscope.length;
      }, options);
      sensor.on(sensor.SensorId.MAGNETIC_FIELD, (data: sensor.MagneticFieldResponse) => {
        if (!this.isRecording || this.isPaused) {
          return;
        }
        this.latestMagneticField = [data.x, data.y, data.z];
        this.latestMagneticAccuracy = Number(data.accuracy) - 1;
        this.magneticMagnitude = Math.sqrt(data.x * data.x + data.y * data.y + data.z * data.z);
        this.magnetometer.push(new VectorSample(this.sensorTime(data.timestamp), data.x, data.y, data.z,
          Number(data.accuracy)));
        this.counts.magnetometer = this.magnetometer.length;
      }, options);
    } catch (error) {
      this.statusMessage = `必需传感器启动失败：${String(error)}`;
      this.isRecording = false;
      this.unsubscribeSensors();
      return false;
    }

    try {
      sensor.on(sensor.SensorId.GRAVITY, (data: sensor.GravityResponse) => {
        this.latestGravity = [data.x, data.y, data.z];
      }, options);
    } catch (error) {
      // Gravity is optional; rotation-vector samples can still be recorded without it.
    }

    try {
      sensor.on(sensor.SensorId.LINEAR_ACCELEROMETER, (data: sensor.LinearAccelerometerResponse) => {
        this.latestLinearAcceleration = [data.x, data.y, data.z];
      }, options);
    } catch (error) {
      // Some simulators do not expose a derived linear-acceleration sensor.
    }

    try {
      sensor.on(sensor.SensorId.ROTATION_VECTOR, (data: sensor.RotationVectorResponse) => {
        if (!this.isRecording || this.isPaused) {
          return;
        }
        let quaternion: number[] = [data.x, data.y, data.z, data.w];
        let attitude: number[] = this.quaternionToAttitude(quaternion);
        this.rollDegrees = attitude[0] * 180 / Math.PI;
        this.pitchDegrees = attitude[1] * 180 / Math.PI;
        this.yawDegrees = this.normalizeDegrees(attitude[2] * 180 / Math.PI);
        if (!this.hasInitialDeviceYaw) {
          this.initialDeviceYaw = this.yawDegrees;
          this.hasInitialDeviceYaw = true;
        }
        this.globalHeadingDegrees = this.normalizeDegrees(this.config.initialHeadingDegrees +
          this.shortestAngleDifference(this.yawDegrees, this.initialDeviceYaw));
        this.deviceMotion.push(new MotionSample(this.sensorTime(data.timestamp), quaternion, attitude,
          this.latestGravity, this.latestLinearAcceleration, this.latestGyroscope, this.latestMagneticField,
          this.latestMagneticAccuracy));
        this.counts.deviceMotion = this.deviceMotion.length;
      }, options);
    } catch (error) {
      // UI flow and raw sensor capture remain usable when a simulator lacks attitude data.
    }

    try {
      sensor.on(sensor.SensorId.MAGNETIC_FIELD_UNCALIBRATED,
        (data: sensor.MagneticFieldUncalibratedResponse) => {
          if (!this.isRecording || this.isPaused) {
            return;
          }
          this.magnetometerRaw.push(new VectorSample(this.sensorTime(data.timestamp), data.x, data.y, data.z,
            Number(data.accuracy)));
        }, options);
    } catch (error) {
      // Some devices expose only the calibrated magnetic field. The required stream is still available.
    }
    return true;
  }

  private unsubscribeSensors(): void {
    try { sensor.off(sensor.SensorId.ACCELEROMETER); } catch (error) {}
    try { sensor.off(sensor.SensorId.GYROSCOPE); } catch (error) {}
    try { sensor.off(sensor.SensorId.MAGNETIC_FIELD); } catch (error) {}
    try { sensor.off(sensor.SensorId.MAGNETIC_FIELD_UNCALIBRATED); } catch (error) {}
    try { sensor.off(sensor.SensorId.GRAVITY); } catch (error) {}
    try { sensor.off(sensor.SensorId.LINEAR_ACCELEROMETER); } catch (error) {}
    try { sensor.off(sensor.SensorId.ROTATION_VECTOR); } catch (error) {}
  }

  private sensorTime(timestamp: number): number {
    if (this.firstSensorTimestamp < 0) {
      this.firstSensorTimestamp = timestamp;
    }
    return Math.max(0, (timestamp - this.firstSensorTimestamp) / 1000000000);
  }

  private currentTime(): number {
    return Math.max(0, (Date.now() - this.startWallMilliseconds) / 1000);
  }

  private currentHeading(): number {
    return this.hasInitialDeviceYaw ? this.globalHeadingDegrees : this.config.initialHeadingDegrees;
  }

  private quaternionToAttitude(quaternion: number[]): number[] {
    let x = quaternion[0];
    let y = quaternion[1];
    let z = quaternion[2];
    let w = quaternion[3];
    let roll = Math.atan2(2 * (w * x + y * z), 1 - 2 * (x * x + y * y));
    let pitchTerm = 2 * (w * y - z * x);
    let pitch = Math.asin(Math.max(-1, Math.min(1, pitchTerm)));
    let yaw = Math.atan2(2 * (w * z + x * y), 1 - 2 * (y * y + z * z));
    return [roll, pitch, yaw];
  }

  private normalizeDegrees(value: number): number {
    let result = value % 360;
    return result < 0 ? result + 360 : result;
  }

  private shortestAngleDifference(current: number, reference: number): number {
    let difference = (current - reference + 540) % 360 - 180;
    return difference;
  }
}
