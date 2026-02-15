//! BK board for e2e hal/temp_sensor
const bk = @import("bk");
pub const log = bk.impl.log.scoped("e2e");
pub const TempDriver = bk.impl.TempSensorDriver;
