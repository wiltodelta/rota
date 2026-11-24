//! Native macOS trackpad rubber-band overscroll, auto-fading scrollbars, and draggable scrollbar thumb math.

use winit::event::TouchPhase;

use crate::window_types::ActivityClock;

#[derive(Debug, Clone, Copy)]
pub struct ScrollPhysics {
    pub overscroll_y: f32,
    pub touch_active: bool,
    pub last_activity_time: Option<f64>,
    pub last_tick_time: Option<f64>,
}

impl Default for ScrollPhysics {
    fn default() -> Self {
        Self::new()
    }
}

impl ScrollPhysics {
    const MAX_OVERSCROLL: f32 = 88.0;
    const VISIBLE_HOLD_SECS: f64 = 0.70;
    const FADE_DURATION_SECS: f64 = 0.24;

    pub const fn new() -> Self {
        Self {
            overscroll_y: 0.0,
            touch_active: false,
            last_activity_time: None,
            last_tick_time: None,
        }
    }

    pub fn note_activity(&mut self, now_seconds: f64) {
        if now_seconds > 0.0 {
            self.last_activity_time = Some(now_seconds);
        }
    }

    /// Applies rubber-band resistance (`UIScrollView`/`NSScrollView` curve) when trackpad scrolls past `[0, max_y]`.
    pub fn apply_trackpad_delta(
        &mut self,
        scroll_y: &mut f32,
        dy_pt: f32,
        max_y: f32,
        phase: TouchPhase,
        is_pixel_delta: bool,
        now_seconds: f64,
    ) {
        self.note_activity(now_seconds);
        match phase {
            TouchPhase::Started | TouchPhase::Moved => {
                self.touch_active = is_pixel_delta;
            }
            TouchPhase::Ended | TouchPhase::Cancelled => {
                self.touch_active = false;
            }
        }

        if !is_pixel_delta {
            *scroll_y = (*scroll_y + dy_pt).clamp(0.0, max_y);
            self.overscroll_y = 0.0;
            return;
        }

        // Consume existing overscroll first if user reverses direction.
        let mut rem = dy_pt;
        if self.overscroll_y != 0.0 && self.overscroll_y.signum() != rem.signum() {
            let next_over = self.overscroll_y + rem;
            if next_over.signum() != self.overscroll_y.signum() {
                rem = next_over;
                self.overscroll_y = 0.0;
            } else {
                self.overscroll_y = next_over;
                return;
            }
        }

        let unclamped = *scroll_y + rem;
        if unclamped < 0.0 {
            let excess = unclamped;
            *scroll_y = 0.0;
            if self.touch_active {
                let resist = 0.36 / (1.0 + self.overscroll_y.abs() / 80.0);
                self.overscroll_y =
                    (self.overscroll_y + excess * resist).clamp(-Self::MAX_OVERSCROLL, Self::MAX_OVERSCROLL);
            }
        } else if unclamped > max_y {
            let excess = unclamped - max_y;
            *scroll_y = max_y;
            if self.touch_active {
                let resist = 0.36 / (1.0 + self.overscroll_y.abs() / 80.0);
                self.overscroll_y =
                    (self.overscroll_y + excess * resist).clamp(-Self::MAX_OVERSCROLL, Self::MAX_OVERSCROLL);
            }
        } else {
            *scroll_y = unclamped;
        }
    }

    /// Springs `overscroll_y` smoothly back to `0.0` once trackpad fingers release, idling at 0% CPU when settled.
    pub fn tick(&mut self, now_seconds: f64, clock: &mut ActivityClock) {
        let raw_dt = self.last_tick_time.map_or(1.0 / 120.0, |prev| {
            ((now_seconds - prev) as f32).clamp(0.001, 0.05)
        });
        self.last_tick_time = Some(now_seconds);

        if !self.touch_active && self.overscroll_y.abs() > 0.0 {
            let decay = (-18.0 * raw_dt).exp();
            self.overscroll_y *= decay;
            if self.overscroll_y.abs() < 0.25 {
                self.overscroll_y = 0.0;
            } else {
                clock.mark_active();
            }
        }
    }

    /// Computes scrollbar visibility (`0.22` subtle baseline or `1.0` active, fading smoothly after scrolling).
    pub fn scrollbar_alpha(
        &self,
        now_seconds: f64,
        hovered_or_dragging: bool,
        clock: &mut ActivityClock,
    ) -> f32 {
        if hovered_or_dragging {
            return 1.0;
        }
        let Some(last) = self.last_activity_time else {
            return 0.26;
        };
        let elapsed = (now_seconds - last).max(0.0);
        if elapsed < Self::VISIBLE_HOLD_SECS {
            clock.mark_active();
            1.0
        } else if elapsed < Self::VISIBLE_HOLD_SECS + Self::FADE_DURATION_SECS {
            clock.mark_active();
            let t = ((elapsed - Self::VISIBLE_HOLD_SECS) / Self::FADE_DURATION_SECS) as f32;
            1.0 - t * (1.0 - 0.26)
        } else {
            0.26
        }
    }
}

/// Converts a pointer Y coordinate inside a scrollbar track into the target `scroll_y`.
pub fn scroll_y_from_track_pointer(
    local_y: f32,
    viewport_h: f32,
    total_h: f32,
    grab_offset_in_thumb: Option<f32>,
) -> f32 {
    if total_h <= viewport_h {
        return 0.0;
    }
    let track_pad = 6.0;
    let track_h = (viewport_h - track_pad * 2.0).max(24.0);
    let ratio = (viewport_h / total_h).clamp(0.08, 0.92);
    let thumb_h = (track_h * ratio).max(24.0);
    let usable = (track_h - thumb_h).max(1.0);
    let anchor = grab_offset_in_thumb.unwrap_or(thumb_h * 0.5);
    let frac = ((local_y - track_pad - anchor) / usable).clamp(0.0, 1.0);
    frac * (total_h - viewport_h)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rubber_band_stretches_on_touch_and_rebounds_to_zero() {
        let mut phys = ScrollPhysics::new();
        let mut scroll_y = 0.0;
        phys.apply_trackpad_delta(&mut scroll_y, -80.0, 500.0, TouchPhase::Moved, true, 1.0);
        assert_eq!(scroll_y, 0.0);
        assert!(phys.overscroll_y < -10.0);

        phys.apply_trackpad_delta(&mut scroll_y, 0.0, 500.0, TouchPhase::Ended, true, 1.05);
        let mut clock = ActivityClock::new();
        let mut t = 1.05;
        for _ in 0..45 {
            clock.reset_frame();
            t += 1.0 / 60.0;
            phys.tick(t, &mut clock);
        }
        assert_eq!(phys.overscroll_y, 0.0);
        assert!(!clock.needs_continuous_redraw());
    }
}
