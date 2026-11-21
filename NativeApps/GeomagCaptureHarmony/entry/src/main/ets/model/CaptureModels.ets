export class VectorSample {
  time: number;
  x: number;
  y: number;
  z: number;
  accuracy: number;

  constructor(time: number, x: number, y: number, z: number, accuracy: number = -1) {
    this.time = time;
    this.x = x;
    this.y = y;
    this.z = z;
    this.accuracy = accuracy;
  }
}

export class MotionSample {
  time: number;
  quaternionX: number;
  quaternionY: number;
  quaternionZ: number;
  quaternionW: number;
  roll: number;
  pitch: number;
  yaw: number;
  gravityX: number;
  gravityY: number;
  gravityZ: number;
  userAccelerationX: number;
  userAccelerationY: number;
  userAccelerationZ: number;
  rotationRateX: number;
  rotationRateY: number;
  rotationRateZ: number;
  magneticFieldX: number;
  magneticFieldY: number;
  magneticFieldZ: number;
  magneticAccuracy: number;

  constructor(time: number, quaternion: number[], attitude: number[], gravity: number[], userAcceleration: number[],
    rotationRate: number[], magneticField: number[], magneticAccuracy: number) {
    this.time = time;
    this.quaternionX = quaternion[0];
    this.quaternionY = quaternion[1];
    this.quaternionZ = quaternion[2];
    this.quaternionW = quaternion[3];
    this.roll = attitude[0];
    this.pitch = attitude[1];
    this.yaw = attitude[2];
    this.gravityX = gravity[0];
    this.gravityY = gravity[1];
    this.gravityZ = gravity[2];
    this.userAccelerationX = userAcceleration[0];
    this.userAccelerationY = userAcceleration[1];
    this.userAccelerationZ = userAcceleration[2];
    this.rotationRateX = rotationRate[0];
    this.rotationRateY = rotationRate[1];
    this.rotationRateZ = rotationRate[2];
    this.magneticFieldX = magneticField[0];
    this.magneticFieldY = magneticField[1];
    this.magneticFieldZ = magneticField[2];
    this.magneticAccuracy = magneticAccuracy;
  }
}

export class SpatialEvent {
  time: number;
  type: string;
  label: string;
  x?: number;
  y?: number;
  headingDegrees?: number;
  deviceYawDegrees?: number;

  constructor(time: number, type: string, label: string, x?: number, y?: number,
    headingDegrees?: number, deviceYawDegrees?: number) {
    this.time = time;
    this.type = type;
    this.label = label;
    this.x = x;
    this.y = y;
    this.headingDegrees = headingDegrees;
    this.deviceYawDegrees = deviceYawDegrees;
  }
}

export class RoutePoint {
  x: number;
  y: number;
  phase: string;

  constructor(x: number, y: number, phase: string = 'horizontal') {
    this.x = x;
    this.y = y;
    this.phase = phase;
  }
}

export class CaptureConfig {
  datasetKey: string = '';
  coordinateFrame: string = '';
  startX: number = 0;
  startY: number = 0;
  initialHeadingDegrees: number = 0;
  routeDirection: string = 'forward';
  route: RoutePoint[] = [];
  sampleRateHz: number = 100;
}

export class CaptureCounts {
  accelerometer: number = 0;
  gyroscope: number = 0;
  magnetometer: number = 0;
  deviceMotion: number = 0;
}

export class CaptureSnapshot {
  config: CaptureConfig;
  startedAt: Date;
  stoppedAt: Date;
  accelerometer: VectorSample[];
  gyroscope: VectorSample[];
  magnetometer: VectorSample[];
  magnetometerRaw: VectorSample[];
  deviceMotion: MotionSample[];
  spatialEvents: SpatialEvent[];

  constructor(config: CaptureConfig, startedAt: Date, stoppedAt: Date, accelerometer: VectorSample[],
    gyroscope: VectorSample[], magnetometer: VectorSample[], magnetometerRaw: VectorSample[],
    deviceMotion: MotionSample[], spatialEvents: SpatialEvent[]) {
    this.config = config;
    this.startedAt = startedAt;
    this.stoppedAt = stoppedAt;
    this.accelerometer = accelerometer;
    this.gyroscope = gyroscope;
    this.magnetometer = magnetometer;
    this.magnetometerRaw = magnetometerRaw;
    this.deviceMotion = deviceMotion;
    this.spatialEvents = spatialEvents;
  }
}
