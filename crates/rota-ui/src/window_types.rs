//! Window configuration and 120 Hz on-demand `ActivityClock` types.

use crate::geometry::Size;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum WindowAppearance {
    #[default]
    System,
    Light,
    Dark,
}

/// Analytical 120 Hz motion clock that requests continuous redraws ONLY while spinners/pulses are visible.
#[derive(Debug, Clone, Default)]
pub struct ActivityClock {
    active_animations: u32,
    pub reduce_motion: bool,
}

impl ActivityClock {
    pub fn new() -> Self {
        Self::default()
    }
    pub fn set_reduce_motion(&mut self, reduce_motion: bool) {
        self.reduce_motion = reduce_motion;
    }
    pub fn reset_frame(&mut self) {
        self.active_animations = 0;
    }
    pub fn mark_active(&mut self) {
        self.active_animations += 1;
    }
    pub fn needs_continuous_redraw(&self) -> bool {
        self.active_animations > 0
    }
    pub fn spinner_angle_rad(&mut self, now_seconds: f64) -> f32 {
        if self.reduce_motion {
            return 0.0;
        }
        self.mark_active();
        ((now_seconds * 1.25).fract() * std::f64::consts::TAU) as f32
    }
    pub fn pulse_opacity(&mut self, now_seconds: f64) -> f32 {
        if self.reduce_motion {
            return 1.0;
        }
        self.mark_active();
        0.35 + 0.65 * (((now_seconds * 2.4).sin() * 0.5 + 0.5) as f32)
    }
}

#[derive(Debug, Clone)]
pub struct WindowConfig {
    pub title: String,
    pub initial_size: Size,
    pub min_size: Size,
    pub appearance: WindowAppearance,
    pub decorations: bool,
    pub resizable: bool,
    pub fullsize_content_view: bool,
    pub vibrant: bool,
    pub initial_visible: bool,
    pub exit_on_close: bool,
}

impl Default for WindowConfig {
    fn default() -> Self {
        Self {
            title: "Rota".to_string(),
            initial_size: Size::new(1080.0, 720.0),
            min_size: Size::new(820.0, 520.0),
            appearance: WindowAppearance::System,
            decorations: true,
            resizable: true,
            fullsize_content_view: true,
            vibrant: true,
            initial_visible: true,
            exit_on_close: false,
        }
    }
}
