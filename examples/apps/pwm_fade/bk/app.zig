//! PWM Fade Test — BK7258
//!
//! Smoothly fades a PWM output (e.g. LED brightness).

const bk = @import("bk");
const armino = bk.armino;

const PWM_CHANNEL: u32 = 0;
const PWM_PERIOD_US: u32 = 1000; // 1kHz

export fn zig_main() void {
    armino.log.info("ZIG", "==========================================");
    armino.log.info("ZIG", "       PWM Fade Test (BK7258)");
    armino.log.info("ZIG", "==========================================");

    armino.pwm.init(PWM_CHANNEL, PWM_PERIOD_US, 0) catch {
        armino.log.err("ZIG", "PWM init failed");
        return;
    };
    armino.pwm.start(PWM_CHANNEL) catch {
        armino.log.err("ZIG", "PWM start failed");
        return;
    };

    armino.log.info("ZIG", "PWM running, fading...");

    var duty: u32 = 0;
    var increasing = true;

    while (true) {
        armino.pwm.setDuty(PWM_CHANNEL, duty) catch {};

        if (increasing) {
            duty += 10;
            if (duty >= PWM_PERIOD_US) { duty = PWM_PERIOD_US; increasing = false; }
        } else {
            if (duty >= 10) duty -= 10 else { duty = 0; increasing = true; }
        }

        armino.time.sleepMs(10);
    }
}
