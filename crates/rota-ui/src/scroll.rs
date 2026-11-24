//! `O(log N)` prefix-sum virtual scroll engine with reading-anchor preservation and sticky bottom.

use std::ops::Range;

use winit::event::TouchPhase;

use crate::scroll_physics::ScrollPhysics;
use crate::window_types::ActivityClock;

#[derive(Debug, Clone, PartialEq)]
pub struct VirtualVisibleRange {
    pub indices: Range<usize>,
    pub top_spacer: f32,
    pub bottom_spacer: f32,
    pub first_item_top_y: f32,
}

/// High-frequency virtualized transcript scroll state supporting thousands of heterogeneous items.
#[derive(Debug, Clone)]
pub struct VirtualScrollState {
    heights: Vec<f32>,
    /// Prefix sums of length `heights.len() + 1` where `prefix[0] = 0.0` and `prefix[i]` is top of item `i`.
    prefix: Vec<f64>,
    pub scroll_y: f32,
    pub target_scroll_y: Option<f32>,
    pub stick_to_bottom: bool,
    pub sticky_threshold_pt: f32,
    pub physics: ScrollPhysics,
}

impl Default for VirtualScrollState {
    fn default() -> Self {
        Self::new()
    }
}

impl VirtualScrollState {
    pub const DEFAULT_STICKY_THRESHOLD: f32 = 24.0;

    pub fn new() -> Self {
        Self {
            heights: Vec::new(),
            prefix: vec![0.0],
            scroll_y: 0.0,
            target_scroll_y: None,
            stick_to_bottom: true,
            sticky_threshold_pt: Self::DEFAULT_STICKY_THRESHOLD,
            physics: ScrollPhysics::new(),
        }
    }

    pub fn new_top() -> Self {
        Self {
            stick_to_bottom: false,
            ..Self::new()
        }
    }

    #[inline]
    pub fn item_count(&self) -> usize {
        self.heights.len()
    }

    #[inline]
    pub fn total_height(&self) -> f32 {
        self.prefix.last().copied().unwrap_or(0.0) as f32
    }

    #[inline]
    pub fn max_scroll_y(&self, viewport_height: f32) -> f32 {
        (self.total_height() - viewport_height.max(0.0)).max(0.0)
    }

    #[inline]
    pub fn item_top(&self, index: usize) -> f32 {
        self.prefix.get(index).copied().unwrap_or(0.0) as f32
    }

    #[inline]
    pub fn item_height(&self, index: usize) -> f32 {
        self.heights.get(index).copied().unwrap_or(0.0)
    }

    /// Replaces item heights (recomputing prefix sums) and enforces `stick_to_bottom` if pinned.
    pub fn set_heights(&mut self, heights: &[f32], viewport_height: f32) {
        self.heights.clear();
        self.heights.reserve(heights.len());
        self.prefix.clear();
        self.prefix.reserve(heights.len() + 1);
        self.prefix.push(0.0);
        let mut acc = 0.0f64;
        for &h in heights {
            let clamped = h.max(0.0);
            self.heights.push(clamped);
            acc += f64::from(clamped);
            self.prefix.push(acc);
        }
        if self.stick_to_bottom {
            self.scroll_y = self.max_scroll_y(viewport_height);
            self.target_scroll_y = None;
        } else {
            self.scroll_y = self.scroll_y.clamp(0.0, self.max_scroll_y(viewport_height));
        }
    }

    /// Updates a single item's measured height (`O(N - index)` prefix tail update) while maintaining bottom pin.
    pub fn update_item_height(&mut self, index: usize, new_height: f32, viewport_height: f32) {
        if index >= self.heights.len() {
            return;
        }
        let clamped = new_height.max(0.0);
        let old = self.heights[index];
        if (clamped - old).abs() < 0.01 {
            return;
        }
        self.heights[index] = clamped;
        let mut acc = self.prefix[index];
        for i in index..self.heights.len() {
            acc += f64::from(self.heights[i]);
            self.prefix[i + 1] = acc;
        }
        if self.stick_to_bottom {
            self.scroll_y = self.max_scroll_y(viewport_height);
        } else {
            self.scroll_y = self.scroll_y.clamp(0.0, self.max_scroll_y(viewport_height));
        }
    }

    /// Appends a new item at the bottom, following automatically if `stick_to_bottom` is active.
    pub fn push_item(&mut self, height: f32, viewport_height: f32) {
        let clamped = height.max(0.0);
        self.heights.push(clamped);
        let next = self.prefix.last().copied().unwrap_or(0.0) + f64::from(clamped);
        self.prefix.push(next);
        if self.stick_to_bottom {
            self.scroll_y = self.max_scroll_y(viewport_height);
        }
    }

    /// Prepends earlier history items at index `0` while preserving the exact pixel reading anchor.
    pub fn preserve_anchor_on_prepend(&mut self, prepended_heights: &[f32], viewport_height: f32) {
        if prepended_heights.is_empty() {
            return;
        }
        let added: f64 = prepended_heights.iter().map(|&h| f64::from(h.max(0.0))).sum();
        let mut combined = Vec::with_capacity(prepended_heights.len() + self.heights.len());
        combined.extend(prepended_heights.iter().map(|&h| h.max(0.0)));
        combined.extend_from_slice(&self.heights);

        let was_sticky = self.stick_to_bottom;
        let shifted_scroll = self.scroll_y + (added as f32);
        self.stick_to_bottom = false;
        self.set_heights(&combined, viewport_height);
        if was_sticky {
            self.stick_to_bottom = true;
            self.scroll_y = self.max_scroll_y(viewport_height);
        } else {
            self.scroll_y = shifted_scroll.clamp(0.0, self.max_scroll_y(viewport_height));
        }
    }

    /// Applies user scroll input (`delta_y_pt > 0.0` scrolls downward toward newer content).
    pub fn apply_scroll_delta(&mut self, delta_y_pt: f32, viewport_height: f32) {
        let max_y = self.max_scroll_y(viewport_height);
        self.scroll_y = (self.scroll_y + delta_y_pt).clamp(0.0, max_y);
        self.target_scroll_y = None;
        self.stick_to_bottom = (max_y - self.scroll_y) <= self.sticky_threshold_pt;
    }

    #[inline]
    pub fn effective_scroll_y(&self) -> f32 {
        self.scroll_y + self.physics.overscroll_y
    }

    /// Translates `winit` wheel/trackpad events (`LineDelta` or `PixelDelta`) into logical points.
    pub fn handle_wheel_delta(
        &mut self,
        delta: winit::event::MouseScrollDelta,
        scale_factor: f32,
        viewport_height: f32,
    ) {
        self.handle_wheel_delta_with_phase(delta, TouchPhase::Moved, scale_factor, viewport_height, 0.0);
        self.physics.touch_active = false;
        self.physics.overscroll_y = 0.0;
    }

    pub fn handle_wheel_delta_with_phase(
        &mut self,
        delta: winit::event::MouseScrollDelta,
        phase: TouchPhase,
        scale_factor: f32,
        viewport_height: f32,
        now_seconds: f64,
    ) {
        let (dy_pt, is_pixel) = match delta {
            winit::event::MouseScrollDelta::LineDelta(_, lines_y) => (-lines_y * 36.0, false),
            winit::event::MouseScrollDelta::PixelDelta(pos) => {
                (-(pos.y as f32) / scale_factor.max(1.0), true)
            }
        };
        let max_y = self.max_scroll_y(viewport_height);
        self.target_scroll_y = None;
        self.physics
            .apply_trackpad_delta(&mut self.scroll_y, dy_pt, max_y, phase, is_pixel, now_seconds);
        self.stick_to_bottom = (max_y - self.scroll_y) <= self.sticky_threshold_pt;
    }

    pub fn tick_physics(&mut self, now_seconds: f64, viewport_height: f32, clock: &mut ActivityClock) {
        self.physics.tick(now_seconds, clock);
        if self.tick_animation(1.0 / 120.0, viewport_height) {
            clock.mark_active();
        }
    }

    pub fn scroll_to_bottom(&mut self, viewport_height: f32, animated: bool) {
        let max_y = self.max_scroll_y(viewport_height);
        self.stick_to_bottom = true;
        if animated {
            self.target_scroll_y = Some(max_y);
        } else {
            self.scroll_y = max_y;
            self.target_scroll_y = None;
        }
    }

    pub fn scroll_to_item(&mut self, index: usize, viewport_height: f32) {
        if index >= self.heights.len() {
            return;
        }
        let max_y = self.max_scroll_y(viewport_height);
        let top = self.item_top(index);
        let bottom = top + self.heights[index];
        if top < self.scroll_y {
            self.scroll_y = top.clamp(0.0, max_y);
        } else if bottom > self.scroll_y + viewport_height {
            self.scroll_y = (bottom - viewport_height).clamp(0.0, max_y);
        }
        self.stick_to_bottom = (max_y - self.scroll_y) <= self.sticky_threshold_pt;
    }

    /// Advances smooth scroll animation; returns `true` while still animating.
    pub fn tick_animation(&mut self, dt_seconds: f32, viewport_height: f32) -> bool {
        let Some(target) = self.target_scroll_y else {
            return false;
        };
        let max_y = self.max_scroll_y(viewport_height);
        let clamped_target = target.clamp(0.0, max_y);
        let diff = clamped_target - self.scroll_y;
        if diff.abs() < 0.5 {
            self.scroll_y = clamped_target;
            self.target_scroll_y = None;
            return false;
        }
        let alpha = 1.0 - (-18.0 * dt_seconds.clamp(0.001, 0.1)).exp();
        self.scroll_y += diff * alpha;
        true
    }

    /// `O(log N)` binary search over the prefix-sum table returning the visible slice + spacers.
    pub fn visible_range(&self, viewport_height: f32, overscan_px: f32) -> VirtualVisibleRange {
        let n = self.heights.len();
        if n == 0 {
            return VirtualVisibleRange {
                indices: 0..0,
                top_spacer: 0.0,
                bottom_spacer: 0.0,
                first_item_top_y: 0.0,
            };
        }
        let view_min = f64::from((self.scroll_y - overscan_px.max(0.0)).max(0.0));
        let view_max = f64::from(self.scroll_y + viewport_height.max(0.0) + overscan_px.max(0.0));

        // Find first item `start` whose bottom (`prefix[start + 1]`) > `view_min`.
        let start = self.prefix[1..=n]
            .partition_point(|&bottom| bottom <= view_min)
            .min(n - 1);

        // Find exclusive `end` whose top (`prefix[end]`) < `view_max`.
        let end = self.prefix[..n]
            .partition_point(|&top| top < view_max)
            .max(start + 1)
            .min(n);

        let top_spacer = self.prefix[start] as f32;
        let bottom_spacer = (self.prefix[n] - self.prefix[end]).max(0.0) as f32;
        VirtualVisibleRange {
            indices: start..end,
            top_spacer,
            bottom_spacer,
            first_item_top_y: top_spacer - self.scroll_y,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn binary_search_visible_range_and_prepend_anchor_preservation() {
        let mut vs = VirtualScrollState::new();
        let heights: Vec<f32> = (0..10_000).map(|i| 40.0 + (i % 5) as f32 * 10.0).collect();
        vs.set_heights(&heights, 500.0);
        assert!(vs.stick_to_bottom);

        // Scroll upward to detach from bottom and read item #2500.
        let anchor_index = 2500usize;
        let anchor_top_before = vs.item_top(anchor_index);
        vs.apply_scroll_delta(-(vs.scroll_y - (anchor_top_before - 32.0)), 500.0);
        assert!(!vs.stick_to_bottom);
        let screen_offset_before = vs.item_top(anchor_index) - vs.scroll_y;
        assert!((screen_offset_before - 32.0).abs() < 0.01);

        let vis = vs.visible_range(500.0, 0.0);
        assert!(vis.indices.contains(&anchor_index));
        assert!(vis.indices.len() <= 15);

        // Prepend 50 older history items at the top: anchor item shifts to index 2550 with IDENTICAL screen Y!
        let older = vec![64.0f32; 50];
        vs.preserve_anchor_on_prepend(&older, 500.0);
        let screen_offset_after = vs.item_top(anchor_index + 50) - vs.scroll_y;
        assert!((screen_offset_after - screen_offset_before).abs() < 0.01);
    }
}
