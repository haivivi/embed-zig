/**
 * bk_zig_pwm_helper.c — PWM helpers for Zig.
 */
#include <driver/pwm.h>
#include <driver/pwm_types.h>

int bk_zig_pwm_init(unsigned int channel, unsigned int period_us, unsigned int duty_cycle) {
    pwm_init_config_t config = {0};
    config.period_cycle = period_us;
    config.duty_cycle = duty_cycle;
    return bk_pwm_init(channel, &config);
}

int bk_zig_pwm_start(unsigned int channel) {
    return bk_pwm_start(channel);
}

int bk_zig_pwm_stop(unsigned int channel) {
    return bk_pwm_stop(channel);
}

int bk_zig_pwm_set_duty(unsigned int channel, unsigned int duty_cycle) {
    pwm_period_duty_config_t config = {0};
    config.duty_cycle = duty_cycle;
    return bk_pwm_set_period_duty(channel, &config);
}
