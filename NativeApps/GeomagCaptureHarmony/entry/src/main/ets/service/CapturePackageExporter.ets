import { common } from '@kit.AbilityKit';
import { zlib } from '@kit.BasicServicesKit';
import { fileIo as fs, picker } from '@kit.CoreFileKit';
import {
  CaptureSnapshot,
  MotionSample,
  RoutePoint,
  SpatialEvent,
  VectorSample
} from '../model/CaptureModels';

class SpatialMetadata {
  coordinate_frame: string;
  unit: string = 'm';
  start_position_xy_m: number[];
  initial_heading_deg: number;

  constructor(frame: string, startX: number, startY: number, heading: number) {
    this.coordinate_frame = frame;
    this.start_position_xy_m = [startX, startY];
    this.initial_heading_deg = heading;
  }
}

class StreamMetadata {
  file: string;
  samples: number;
  observed_rate_hz: number;

  constructor(file: string, samples: number, observedRateHz: number) {
    this.file = file;
    this.samples = samples;
    this.observed_rate_hz = observedRateHz;
  }
}

class StreamsMetadata {
  accelerometer: StreamMetadata;
  gyroscope: StreamMetadata;
  magnetometer: StreamMetadata;
  magnetometer_raw: StreamMetadata;
  device_motion: StreamMetadata;
  spatial_events: StreamMetadata;

  constructor(snapshot: CaptureSnapshot) {
    this.accelerometer = new StreamMetadata('Accelerometer.csv', snapshot.accelerometer.length,
      CapturePackageExporter.observedRate(snapshot.accelerometer, snapshot.spatialEvents));
    this.gyroscope = new StreamMetadata('Gyroscope.csv', snapshot.gyroscope.length,
      CapturePackageExporter.observedRate(snapshot.gyroscope, snapshot.spatialEvents));
    this.magnetometer = new StreamMetadata('Magnetometer.csv', snapshot.magnetometer.length,
      CapturePackageExporter.observedRate(snapshot.magnetometer, snapshot.spatialEvents));
    this.magnetometer_raw = new StreamMetadata('MagnetometerRaw.csv', snapshot.magnetometerRaw.length,
      CapturePackageExporter.observedRate(snapshot.magnetometerRaw, snapshot.spatialEvents));
    this.device_motion = new StreamMetadata('DeviceMotion.csv', snapshot.deviceMotion.length,
      CapturePackageExporter.observedMotionRate(snapshot.deviceMotion, snapshot.spatialEvents));
    this.spatial_events = new StreamMetadata('SpatialEvents.csv', snapshot.spatialEvents.length, 0);
  }
}

class CaptureMetadata {
  format_version: number = 3;
  dataset_key: string;
  created_at: string;
  stopped_at: string;
  duration_seconds: number;
  requested_sample_rate_hz: number;
  timestamp_mode: string = 'seconds_since_capture_start';
  reference_frame: string = 'harmony_device_and_rotation_vector';
  device_pose: string = 'face_up_front_forward';
  platform: string = 'HarmonyOS Phone';
  system_version: string = 'HarmonyOS 6';
  algorithm_magnetic_field_file: string = 'Magnetometer.csv';
  raw_magnetic_field_file: string = 'MagnetometerRaw.csv';
  spatial_reference: SpatialMetadata;
  spatial_events_file: string = 'SpatialEvents.csv';
  route_direction: string;
  streams: StreamsMetadata;

  constructor(snapshot: CaptureSnapshot) {
    this.dataset_key = snapshot.config.datasetKey;
    this.created_at = snapshot.startedAt.toISOString();
    this.stopped_at = snapshot.stoppedAt.toISOString();
    this.duration_seconds = Math.max(0.001,
      (snapshot.stoppedAt.getTime() - snapshot.startedAt.getTime()) / 1000);
    this.requested_sample_rate_hz = snapshot.config.sampleRateHz;
    this.route_direction = snapshot.config.routeDirection;
    this.spatial_reference = new SpatialMetadata(snapshot.config.coordinateFrame, snapshot.config.startX,
      snapshot.config.startY, snapshot.config.initialHeadingDegrees);
    this.streams = new StreamsMetadata(snapshot);
  }
}

class DatasetMetadata {
  format_version: number = 2;
  dataset_key: string;
  route_xy_m: number[][];
  initial_heading_deg: number;
  route_direction: string;
  spatial_reference: SpatialMetadata;
  spatial_events_file: string = 'SpatialEvents.csv';
  device_pose: string = 'face_up_front_forward';
  timestamp_mode: string = 'seconds_since_capture_start';
  created_at: string;

  constructor(snapshot: CaptureSnapshot) {
    this.dataset_key = snapshot.config.datasetKey;
    this.route_xy_m = [];
    for (let index = 0; index < snapshot.config.route.length; index++) {
      let point: RoutePoint = snapshot.config.route[index];
      this.route_xy_m.push([point.x, point.y]);
    }
    this.initial_heading_deg = snapshot.config.initialHeadingDegrees;
    this.route_direction = snapshot.config.routeDirection;
    this.spatial_reference = new SpatialMetadata(snapshot.config.coordinateFrame, snapshot.config.startX,
      snapshot.config.startY, snapshot.config.initialHeadingDegrees);
    this.created_at = snapshot.startedAt.toISOString();
  }
}

export class ExportResult {
  packageDirectory: string;
  archivePath: string;
  archiveName: string;

  constructor(packageDirectory: string, archivePath: string, archiveName: string) {
    this.packageDirectory = packageDirectory;
    this.archivePath = archivePath;
    this.archiveName = archiveName;
  }
}

export class CapturePackageExporter {
  static async build(context: common.UIAbilityContext, snapshot: CaptureSnapshot): Promise<ExportResult> {
    let safeName = CapturePackageExporter.safeFileName(snapshot.config.datasetKey);
    let suffix = CapturePackageExporter.fileTimestamp(snapshot.startedAt);
    let packageName = `${safeName}-${suffix}.geomagcapture`;
    let rootDirectory = `${context.filesDir}/captures`;
    let packageDirectory = `${rootDirectory}/${packageName}`;
    CapturePackageExporter.ensureDirectory(rootDirectory);
    CapturePackageExporter.ensureDirectory(packageDirectory);

    CapturePackageExporter.writeText(`${packageDirectory}/Accelerometer.csv`,
      CapturePackageExporter.vectorCSV(snapshot.accelerometer, 'm/s^2'));
    CapturePackageExporter.writeText(`${packageDirectory}/Gyroscope.csv`,
      CapturePackageExporter.vectorCSV(snapshot.gyroscope, 'rad/s'));
    CapturePackageExporter.writeText(`${packageDirectory}/Magnetometer.csv`,
      CapturePackageExporter.vectorCSV(snapshot.magnetometer, 'µT'));
    CapturePackageExporter.writeText(`${packageDirectory}/MagnetometerRaw.csv`,
      CapturePackageExporter.vectorCSV(snapshot.magnetometerRaw.length > 0
        ? snapshot.magnetometerRaw : snapshot.magnetometer, 'µT'));
    CapturePackageExporter.writeText(`${packageDirectory}/DeviceMotion.csv`,
      CapturePackageExporter.deviceMotionCSV(snapshot.deviceMotion));
    CapturePackageExporter.writeText(`${packageDirectory}/SpatialEvents.csv`,
      CapturePackageExporter.spatialEventsCSV(snapshot.spatialEvents));
    CapturePackageExporter.writeText(`${packageDirectory}/geomag_dataset.json`,
      JSON.stringify(new DatasetMetadata(snapshot), null, 2));
    CapturePackageExporter.writeText(`${packageDirectory}/capture_metadata.json`,
      JSON.stringify(new CaptureMetadata(snapshot), null, 2));
    CapturePackageExporter.writeText(`${packageDirectory}/README.txt`, CapturePackageExporter.packageReadme());

    let archiveName = `${packageName}.zip`;
    let archivePath = `${context.cacheDir}/${archiveName}`;
    try {
      fs.unlinkSync(archivePath);
    } catch (error) {
    }
    await zlib.compressFile(packageDirectory, archivePath,
      { level: zlib.CompressLevel.COMPRESS_LEVEL_DEFAULT_COMPRESSION });
    return new ExportResult(packageDirectory, archivePath, archiveName);
  }

  static async saveArchive(context: common.UIAbilityContext, result: ExportResult): Promise<string> {
    let options = new picker.DocumentSaveOptions();
    options.newFileNames = [result.archiveName];
    let documentPicker = new picker.DocumentViewPicker(context);
    let destinations = await documentPicker.save(options);
    if (destinations.length === 0) {
      throw new Error('没有选择导出位置');
    }
    let source = fs.openSync(result.archivePath, fs.OpenMode.READ_ONLY);
    try {
      let destination = fs.openSync(destinations[0], fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
      try {
        await fs.copyFile(source.fd, destination.fd);
      } finally {
        fs.closeSync(destination);
      }
    } finally {
      fs.closeSync(source);
    }
    return destinations[0];
  }

  static observedRate(samples: VectorSample[], events: SpatialEvent[]): number {
    if (samples.length < 2) {
      return 0;
    }
    let duration = CapturePackageExporter.activeDuration(samples[0].time,
      samples[samples.length - 1].time, events);
    return duration > 0 ? (samples.length - 1) / duration : 0;
  }

  static observedMotionRate(samples: MotionSample[], events: SpatialEvent[]): number {
    if (samples.length < 2) {
      return 0;
    }
    let duration = CapturePackageExporter.activeDuration(samples[0].time,
      samples[samples.length - 1].time, events);
    return duration > 0 ? (samples.length - 1) / duration : 0;
  }

  private static activeDuration(firstTime: number, lastTime: number, events: SpatialEvent[]): number {
    let duration = Math.max(0, lastTime - firstTime);
    let pauseStart = -1;
    for (let index = 0; index < events.length; index++) {
      let event = events[index];
      if (event.type === 'pause' && pauseStart < 0) {
        pauseStart = event.time;
      } else if (event.type === 'resume' && pauseStart >= 0) {
        let overlapStart = Math.max(firstTime, pauseStart);
        let overlapEnd = Math.min(lastTime, event.time);
        duration -= Math.max(0, overlapEnd - overlapStart);
        pauseStart = -1;
      }
    }
    if (pauseStart >= 0) {
      duration -= Math.max(0, lastTime - Math.max(firstTime, pauseStart));
    }
    return Math.max(0, duration);
  }

  private static vectorCSV(samples: VectorSample[], unit: string): string {
    let header = `\"Time (s)\",\"X (${unit})\",\"Y (${unit})\",\"Z (${unit})\"\n`;
    let text = header;
    for (let index = 0; index < samples.length; index++) {
      let sample = samples[index];
      text += `${CapturePackageExporter.number(sample.time)},${CapturePackageExporter.number(sample.x)},` +
        `${CapturePackageExporter.number(sample.y)},${CapturePackageExporter.number(sample.z)}\n`;
    }
    return text;
  }

  private static deviceMotionCSV(samples: MotionSample[]): string {
    let text = 'Time (s),Quaternion X,Quaternion Y,Quaternion Z,Quaternion W,Roll (rad),Pitch (rad),' +
      'Yaw (rad),Gravity X (m/s^2),Gravity Y (m/s^2),Gravity Z (m/s^2),' +
      'User Acceleration X (m/s^2),User Acceleration Y (m/s^2),User Acceleration Z (m/s^2),' +
      'Rotation Rate X (rad/s),Rotation Rate Y (rad/s),Rotation Rate Z (rad/s),' +
      'Magnetic Field X (µT),Magnetic Field Y (µT),Magnetic Field Z (µT),Magnetic Accuracy\n';
    for (let index = 0; index < samples.length; index++) {
      let sample = samples[index];
      let values: number[] = [sample.time, sample.quaternionX, sample.quaternionY, sample.quaternionZ,
        sample.quaternionW, sample.roll, sample.pitch, sample.yaw, sample.gravityX, sample.gravityY,
        sample.gravityZ, sample.userAccelerationX, sample.userAccelerationY, sample.userAccelerationZ,
        sample.rotationRateX, sample.rotationRateY, sample.rotationRateZ, sample.magneticFieldX,
        sample.magneticFieldY, sample.magneticFieldZ, sample.magneticAccuracy];
      text += CapturePackageExporter.numberRow(values);
    }
    return text;
  }

  private static spatialEventsCSV(events: SpatialEvent[]): string {
    let text = 'Time (s),Type,Label,X (m),Y (m),Heading (deg),Device Yaw (deg)\n';
    for (let index = 0; index < events.length; index++) {
      let event = events[index];
      text += `${CapturePackageExporter.number(event.time)},${CapturePackageExporter.csvString(event.type)},` +
        `${CapturePackageExporter.csvString(event.label)},${CapturePackageExporter.optionalNumber(event.x)},` +
        `${CapturePackageExporter.optionalNumber(event.y)},${CapturePackageExporter.optionalNumber(event.headingDegrees)},` +
        `${CapturePackageExporter.optionalNumber(event.deviceYawDegrees)}\n`;
    }
    return text;
  }

  private static numberRow(values: number[]): string {
    let fields: string[] = [];
    for (let index = 0; index < values.length; index++) {
      fields.push(CapturePackageExporter.number(values[index]));
    }
    return `${fields.join(',')}\n`;
  }

  private static number(value: number): string {
    if (!Number.isFinite(value)) {
      return '';
    }
    return value.toPrecision(9).replace(/\.?0+$/, '');
  }

  private static optionalNumber(value?: number): string {
    return value === undefined ? '' : CapturePackageExporter.number(value);
  }

  private static csvString(value: string): string {
    return `\"${value.replace(/\"/g, '\"\"')}\"`;
  }

  private static ensureDirectory(path: string): void {
    try {
      fs.mkdirSync(path, true);
    } catch (error) {
    }
  }

  private static writeText(path: string, content: string): void {
    let file = fs.openSync(path, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
    try {
      fs.writeSync(file.fd, content);
    } finally {
      fs.closeSync(file);
    }
  }

  private static safeFileName(value: string): string {
    let normalized = value.trim().replace(/[^a-zA-Z0-9_-]+/g, '_');
    return normalized.length > 0 ? normalized : 'geomag_capture';
  }

  private static fileTimestamp(date: Date): string {
    let pad = (value: number): string => value.toString().padStart(2, '0');
    return `${date.getFullYear()}${pad(date.getMonth() + 1)}${pad(date.getDate())}-` +
      `${pad(date.getHours())}${pad(date.getMinutes())}${pad(date.getSeconds())}`;
  }

  private static packageReadme(): string {
    return 'Geomag Capture for HarmonyOS\n\n' +
      'This archive contains a .geomagcapture directory compatible with GeomagMac Native.\n' +
      'Unzip it on the Mac, then choose the .geomagcapture directory in the import panel.\n' +
      'Accelerometer and gyroscope use SI units. Magnetic field uses microtesla.\n' +
      'DeviceMotion.csv is derived from HarmonyOS rotation vector, gravity and linear acceleration sensors.\n' +
      'SpatialEvents.csv contains known-coordinate anchors, pause/resume and obstacle skip events.\n';
  }
}
