Geomag Capture

Accelerometer.csv, Gyroscope.csv and Magnetometer.csv use the same headers
and SI units as GeomagMac Native. Magnetometer.csv contains the calibrated
Core Motion magnetic field used by the positioning algorithm, while
MagnetometerRaw.csv preserves the uncalibrated hardware stream for diagnosis.
DeviceMotion.csv adds the quaternion, attitude, gravity, user acceleration,
rotation rate and magnetic calibration accuracy. All timestamps are seconds
since this capture started.