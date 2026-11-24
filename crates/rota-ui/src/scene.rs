//! Immediate/retained frame command list (`Scene`) compiled into a single instanced GPU draw call.

use crate::color::Color;
use crate::geometry::{Corners, Rect};
use crate::primitives::{GpuPrimitive, QuadSpec};

#[inline]
fn pack_clip_corners(c: Corners) -> u32 {
    let q = |v: f32| (v.clamp(0.0, 127.5) * 2.0).round() as u32;
    q(c.top_left) | (q(c.top_right) << 8) | (q(c.bottom_right) << 16) | (q(c.bottom_left) << 24)
}

#[inline]
fn intersect_rounded_clip(parent: (Rect, Corners), child: (Rect, Corners)) -> (Rect, Corners) {
    let (pr, pc) = parent;
    let (cr, cc) = child;
    let r = pr.intersect(cr);
    if r.is_empty() {
        return (r, Corners::ZERO);
    }
    let pick = |px: f32, py: f32, pr_val: f32, cx: f32, cy: f32, cr_val: f32, rx: f32, ry: f32| -> f32 {
        let p_inset = (rx - px).abs().max((ry - py).abs());
        let from_p = (pr_val - p_inset).max(0.0);
        let c_inset = (rx - cx).abs().max((ry - cy).abs());
        let from_c = (cr_val - c_inset).max(0.0);
        from_p.max(from_c)
    };
    let corners = Corners {
        top_left: pick(
            pr.min_x(),
            pr.min_y(),
            pc.top_left,
            cr.min_x(),
            cr.min_y(),
            cc.top_left,
            r.min_x(),
            r.min_y(),
        ),
        top_right: pick(
            pr.max_x(),
            pr.min_y(),
            pc.top_right,
            cr.max_x(),
            cr.min_y(),
            cc.top_right,
            r.max_x(),
            r.min_y(),
        ),
        bottom_right: pick(
            pr.max_x(),
            pr.max_y(),
            pc.bottom_right,
            cr.max_x(),
            cr.max_y(),
            cc.bottom_right,
            r.max_x(),
            r.max_y(),
        ),
        bottom_left: pick(
            pr.min_x(),
            pr.max_y(),
            pc.bottom_left,
            cr.min_x(),
            cr.max_y(),
            cc.bottom_left,
            r.min_x(),
            r.max_y(),
        ),
    };
    (r, corners)
}

#[derive(Debug, Clone)]
pub struct Scene {
    pub clear_color: Color,
    primitives: Vec<GpuPrimitive>,
    overlay_primitives: Vec<GpuPrimitive>,
    clip_stack: Vec<(Rect, Corners, u32)>,
    in_overlay: bool,
}

impl Default for Scene {
    fn default() -> Self {
        Self::new(Color::WHITE)
    }
}

impl Scene {
    pub fn new(clear_color: Color) -> Self {
        Self {
            clear_color,
            primitives: Vec::with_capacity(512),
            overlay_primitives: Vec::new(),
            clip_stack: vec![(Rect::INFINITE_CLIP, Corners::ZERO, 0)],
            in_overlay: false,
        }
    }

    pub fn clear(&mut self, clear_color: Color) {
        self.clear_color = clear_color;
        self.primitives.clear();
        self.overlay_primitives.clear();
        self.clip_stack.clear();
        self.clip_stack.push((Rect::INFINITE_CLIP, Corners::ZERO, 0));
        self.in_overlay = false;
    }

    #[inline]
    pub fn is_in_overlay(&self) -> bool {
        self.in_overlay
    }

    #[inline]
    pub fn current_clip(&self) -> Rect {
        self.clip_stack.last().map_or(Rect::INFINITE_CLIP, |(r, _, _)| *r)
    }

    #[inline]
    fn current_clip_entry(&self) -> (Rect, Corners, u32) {
        self.clip_stack
            .last()
            .copied()
            .unwrap_or((Rect::INFINITE_CLIP, Corners::ZERO, 0))
    }

    pub fn push_clip(&mut self, rect: Rect) {
        self.push_rounded_clip(rect, Corners::ZERO);
    }

    pub fn push_rounded_clip(&mut self, rect: Rect, corners: Corners) {
        let (pr, pc, _) = self.current_clip_entry();
        let (nr, nc) = intersect_rounded_clip((pr, pc), (rect, corners));
        self.clip_stack.push((nr, nc, pack_clip_corners(nc)));
    }

    pub fn pop_clip(&mut self) {
        if self.clip_stack.len() > 1 {
            self.clip_stack.pop();
        }
    }

    /// Routes primitives emitted inside `f` to the top-most overlay stream (popovers, modals, tooltips).
    pub fn with_overlay(&mut self, f: impl FnOnce(&mut Self)) {
        let prev = self.in_overlay;
        self.in_overlay = true;
        self.clip_stack.push((Rect::INFINITE_CLIP, Corners::ZERO, 0));
        f(self);
        self.pop_clip();
        self.in_overlay = prev;
    }

    #[inline]
    pub fn push_raw(&mut self, mut prim: GpuPrimitive) {
        if prim.kind_flags[2] == 0 {
            let (_, _, packed) = self.current_clip_entry();
            prim.kind_flags[2] = packed;
        }
        if self.in_overlay {
            self.overlay_primitives.push(prim);
        } else {
            self.primitives.push(prim);
        }
    }

    #[inline]
    pub fn push_quad(&mut self, spec: QuadSpec) {
        let clip = self.current_clip();
        if !clip.is_empty() {
            self.push_raw(spec.into_gpu(clip));
        }
    }

    #[inline]
    pub fn push_divider(&mut self, bounds: Rect, color: Color) {
        self.push_quad(QuadSpec::solid(bounds, color));
    }

    #[inline]
    pub fn primitive_count(&self) -> usize {
        self.primitives.len() + self.overlay_primitives.len()
    }

    #[inline]
    pub(crate) fn base_primitives(&self) -> &[GpuPrimitive] {
        &self.primitives
    }

    #[inline]
    pub(crate) fn overlay_primitives(&self) -> &[GpuPrimitive] {
        &self.overlay_primitives
    }
}
