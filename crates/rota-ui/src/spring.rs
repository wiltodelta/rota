//! Critically-damped 120 Hz spring animator (`SpringSet`) that settles to exact targets and idles at 0% CPU.

use std::collections::HashMap;

use crate::color::Color;
use crate::window_types::ActivityClock;

#[derive(Debug, Clone, Copy)]
struct SpringEntry {
    value: f32,
    velocity: f32,
    target: f32,
    last_time: f64,
}

/// Keyed collection of critically-damped scalar springs (`omega = 28 rad/s`, `~140 ms` settle).
#[derive(Debug, Clone, Default)]
pub struct SpringSet {
    entries: HashMap<String, SpringEntry>,
}

impl SpringSet {
    const OMEGA: f32 = 28.0;
    const EPSILON_POS: f32 = 0.002;
    const EPSILON_VEL: f32 = 0.015;

    pub fn new() -> Self {
        Self::default()
    }

    /// Evaluates or advances spring `key` toward `target`.
    /// First observation snaps immediately to `target` so initial renders and static captures never start mid-flight.
    pub fn animate(
        &mut self,
        key: impl Into<String>,
        target: f32,
        now_seconds: f64,
        clock: &mut ActivityClock,
    ) -> f32 {
        let key_str = key.into();
        let Some(entry) = self.entries.get_mut(&key_str) else {
            self.entries.insert(
                key_str,
                SpringEntry {
                    value: target,
                    velocity: 0.0,
                    target,
                    last_time: now_seconds,
                },
            );
            return target;
        };

        entry.target = target;
        let raw_dt = (now_seconds - entry.last_time) as f32;
        entry.last_time = now_seconds;

        if clock.reduce_motion {
            entry.value = target;
            entry.velocity = 0.0;
            return target;
        }

        let disp = entry.value - target;
        if disp.abs() <= Self::EPSILON_POS && entry.velocity.abs() <= Self::EPSILON_VEL {
            entry.value = target;
            entry.velocity = 0.0;
            return target;
        }

        // On the very first frame waking from idle (`velocity == 0`), step by one 120 Hz frame;
        // once actively animating, advance by actual wall-clock `raw_dt` (analytical formula is unconditionally stable).
        let dt = if entry.velocity == 0.0 {
            1.0 / 120.0
        } else {
            raw_dt.clamp(1.0 / 240.0, 0.5)
        };

        // Analytical critically-damped harmonic oscillator step: x(t) = (x0 + (v0 + w*x0)*t) * e^(-w*t)
        let w = Self::OMEGA;
        let exp = (-w * dt).exp();
        let c1 = disp;
        let c2 = entry.velocity + w * disp;
        let next_disp = (c1 + c2 * dt) * exp;
        let next_vel = (c2 - w * (c1 + c2 * dt)) * exp;

        if next_disp.abs() <= Self::EPSILON_POS && next_vel.abs() <= Self::EPSILON_VEL {
            entry.value = target;
            entry.velocity = 0.0;
            target
        } else {
            entry.value = target + next_disp;
            entry.velocity = next_vel;
            clock.mark_active();
            entry.value
        }
    }

    pub fn clear(&mut self) {
        self.entries.clear();
    }
}

/// Linearly interpolates two RGBA colors for smooth switch track and pressed-button transitions.
#[inline]
pub fn lerp_color(a: Color, b: Color, t: f32) -> Color {
    let f = t.clamp(0.0, 1.0);
    Color::new(
        a.r + (b.r - a.r) * f,
        a.g + (b.g - a.g) * f,
        a.b + (b.b - a.b) * f,
        a.a + (b.a - a.a) * f,
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn spring_snaps_on_first_read_and_settles_to_zero_cpu() {
        let mut springs = SpringSet::new();
        let mut clock = ActivityClock::new();

        // First frame snaps to initial target without requesting continuous redraws.
        let v0 = springs.animate("switch-1", 0.0, 1.0, &mut clock);
        assert_eq!(v0, 0.0);
        assert!(!clock.needs_continuous_redraw());

        // Flip target to 1.0: animates smoothly across 120 Hz frames and settles within ~250 ms.
        let mut t = 1.0;
        let mut mid_seen = false;
        for _ in 0..40 {
            clock.reset_frame();
            t += 1.0 / 120.0;
            let v = springs.animate("switch-1", 1.0, t, &mut clock);
            if v > 0.1 && v < 0.9 {
                mid_seen = true;
            }
        }
        assert!(mid_seen);
        clock.reset_frame();
        let settled = springs.animate("switch-1", 1.0, t + 0.2, &mut clock);
        assert_eq!(settled, 1.0);
        assert!(!clock.needs_continuous_redraw());
    }
}
