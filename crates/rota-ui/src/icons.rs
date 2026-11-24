//! Supersampled SDF vector icon library and mask-atlas icon cache for `@2x` crispness.

use std::collections::HashMap;

use crate::atlas::{AtlasRegion, TextureAtlas};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum IconKind {
    Plus,
    Play,
    Stop,
    Pause,
    Check,
    ChevronRight,
    ChevronDown,
    Sidebar,
    Calendar,
    Import,
    Settings,
    Sliders,
    Back,
    Search,
    Terminal,
    Folder,
    FileText,
    Paperclip,
    Send,
    ArrowUp,
    Trash,
    Sparkles,
    ExternalLink,
    Copy,
    Warning,
    BubbleAlert,
    EnvelopeBadge,
    Info,
    Question,
    Clock,
    Filter,
    Close,
    Refresh,
    ArrowDown,
    TextFormatSize,
    MinusCircle,
    TrayFull,
    CheckCircle,
    StopCircle,
    PauseCircle,
    Repeat,
    Square,
    Bubbles,
    Wrench,
    Claude,
    Codex,
    Grok,
    Antigravity,
    Shell,
}

impl IconKind {
    pub const ALL: [Self; 49] = [
        Self::Plus,
        Self::Play,
        Self::Stop,
        Self::Pause,
        Self::Check,
        Self::ChevronRight,
        Self::ChevronDown,
        Self::Sidebar,
        Self::Calendar,
        Self::Import,
        Self::Settings,
        Self::Sliders,
        Self::Back,
        Self::Search,
        Self::Terminal,
        Self::Folder,
        Self::FileText,
        Self::Paperclip,
        Self::Send,
        Self::ArrowUp,
        Self::Trash,
        Self::Sparkles,
        Self::ExternalLink,
        Self::Copy,
        Self::Warning,
        Self::BubbleAlert,
        Self::EnvelopeBadge,
        Self::Info,
        Self::Question,
        Self::Clock,
        Self::Filter,
        Self::Close,
        Self::Refresh,
        Self::ArrowDown,
        Self::TextFormatSize,
        Self::MinusCircle,
        Self::TrayFull,
        Self::CheckCircle,
        Self::StopCircle,
        Self::PauseCircle,
        Self::Repeat,
        Self::Square,
        Self::Bubbles,
        Self::Wrench,
        Self::Claude,
        Self::Codex,
        Self::Grok,
        Self::Antigravity,
        Self::Shell,
    ];
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
struct IconCacheKey {
    kind: IconKind,
    pixel_size: u32,
}

/// Caches supersampled vector icons in the GPU mask atlas.
#[derive(Debug, Default)]
pub struct IconCache {
    entries: HashMap<IconCacheKey, AtlasRegion>,
}

impl IconCache {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn resolve(
        &mut self,
        kind: IconKind,
        logical_size: f32,
        scale_factor: f32,
        mask_atlas: &mut TextureAtlas,
    ) -> Option<[f32; 4]> {
        let px = ((logical_size * scale_factor.max(1.0)).round() as u32).clamp(8, 256);
        let key = IconCacheKey { kind, pixel_size: px };
        if let Some(&region) = self.entries.get(&key)
            && region.generation == mask_atlas.generation()
        {
            return Some(mask_atlas.uv_for(region));
        }
        let rgba = rasterize_icon_rgba(kind, px);
        let region = mask_atlas.allocate_and_upload(px, px, rgba)?;
        self.entries.insert(key, region);
        Some(mask_atlas.uv_for(region))
    }
}

/// Rasterizes `kind` onto a `px x px` RGBA8 coverage mask using native macOS SF Symbols / SVG assets
/// when available, falling back to 4x4 supersampled analytical SDF shapes.
pub fn rasterize_icon_rgba(kind: IconKind, px: u32) -> Vec<u8> {
    let px = px.max(8);
    #[cfg(target_os = "macos")]
    if let Some(native) = crate::icons_macos::rasterize_macos_icon(kind, px) {
        return native;
    }
    let mut out = vec![0u8; (px * px * 4) as usize];
    let inv_px = 24.0 / (px as f32);

    for py in 0..px {
        for px_x in 0..px {
            let mut sum = 0.0f32;
            for sy in 0..4 {
                for sx in 0..4 {
                    let gx = (px_x as f32 + (sx as f32 + 0.5) * 0.25) * inv_px;
                    let gy = (py as f32 + (sy as f32 + 0.5) * 0.25) * inv_px;
                    if icon_sdf(kind, gx, gy) <= 0.0 {
                        sum += 1.0;
                    }
                }
            }
            let alpha = ((sum / 16.0) * 255.0).round() as u8;
            if alpha > 0 {
                let idx = ((py * px + px_x) * 4) as usize;
                out[idx] = 255;
                out[idx + 1] = 255;
                out[idx + 2] = 255;
                out[idx + 3] = alpha;
            }
        }
    }
    out
}

#[inline]
fn seg(px: f32, py: f32, ax: f32, ay: f32, bx: f32, by: f32, r: f32) -> f32 {
    let vx = bx - ax;
    let vy = by - ay;
    let wx = px - ax;
    let wy = py - ay;
    let len_sq = vx * vx + vy * vy;
    let t = if len_sq > 1e-6 {
        ((wx * vx + wy * vy) / len_sq).clamp(0.0, 1.0)
    } else {
        0.0
    };
    let dx = wx - vx * t;
    let dy = wy - vy * t;
    (dx * dx + dy * dy).sqrt() - r
}

#[inline]
fn circle_ring(px: f32, py: f32, cx: f32, cy: f32, radius: f32, half_stroke: f32) -> f32 {
    let d = ((px - cx).powi(2) + (py - cy).powi(2)).sqrt();
    (d - radius).abs() - half_stroke
}

#[inline]
fn disc(px: f32, py: f32, cx: f32, cy: f32, radius: f32) -> f32 {
    ((px - cx).powi(2) + (py - cy).powi(2)).sqrt() - radius
}

#[inline]
fn rbox(px: f32, py: f32, cx: f32, cy: f32, hx: f32, hy: f32, r: f32) -> f32 {
    let qx = (px - cx).abs() - (hx - r);
    let qy = (py - cy).abs() - (hy - r);
    let ox = qx.max(0.0);
    let oy = qy.max(0.0);
    (ox * ox + oy * oy).sqrt() + qx.max(qy).min(0.0) - r
}

#[inline]
#[allow(clippy::too_many_arguments)]
fn rbox_stroke(px: f32, py: f32, cx: f32, cy: f32, hx: f32, hy: f32, r: f32, hs: f32) -> f32 {
    rbox(px, py, cx, cy, hx, hy, r).abs() - hs
}

#[inline]
fn triangle(px: f32, py: f32, a: (f32, f32), b: (f32, f32), c: (f32, f32)) -> f32 {
    let e0 = (b.0 - a.0, b.1 - a.1);
    let e1 = (c.0 - b.0, c.1 - b.1);
    let e2 = (a.0 - c.0, a.1 - c.1);
    let v0 = (px - a.0, py - a.1);
    let v1 = (px - b.0, py - b.1);
    let v2 = (px - c.0, py - c.1);
    let s = (e0.0 * e2.1 - e0.1 * e2.0).signum();
    let d0 = seg(px, py, a.0, a.1, b.0, b.1, 0.0);
    let d1 = seg(px, py, b.0, b.1, c.0, c.1, 0.0);
    let d2 = seg(px, py, c.0, c.1, a.0, a.1, 0.0);
    let min_d = d0.min(d1).min(d2);
    let c0 = s * (v0.0 * e0.1 - v0.1 * e0.0);
    let c1 = s * (v1.0 * e1.1 - v1.1 * e1.0);
    let c2 = s * (v2.0 * e2.1 - v2.1 * e2.0);
    if c0 <= 0.0 && c1 <= 0.0 && c2 <= 0.0 {
        -min_d
    } else {
        min_d
    }
}

fn icon_sdf(kind: IconKind, x: f32, y: f32) -> f32 {
    let s = 1.05;
    match kind {
        IconKind::Plus => seg(x, y, 5.0, 12.0, 19.0, 12.0, s).min(seg(x, y, 12.0, 5.0, 12.0, 19.0, s)),
        IconKind::Play => triangle(x, y, (7.0, 5.0), (19.5, 12.0), (7.0, 19.0)) - 0.6,
        IconKind::Stop => rbox(x, y, 12.0, 12.0, 6.0, 6.0, 1.8),
        IconKind::Pause => rbox(x, y, 8.5, 12.0, 2.0, 6.5, 1.0).min(rbox(x, y, 15.5, 12.0, 2.0, 6.5, 1.0)),
        IconKind::Check => seg(x, y, 5.0, 12.5, 10.0, 17.5, s).min(seg(x, y, 10.0, 17.5, 19.5, 7.0, s)),
        IconKind::ChevronRight => seg(x, y, 9.0, 6.0, 15.5, 12.0, s).min(seg(x, y, 15.5, 12.0, 9.0, 18.0, s)),
        IconKind::ChevronDown => seg(x, y, 6.0, 9.5, 12.0, 15.5, s).min(seg(x, y, 12.0, 15.5, 18.0, 9.5, s)),
        IconKind::Sidebar => {
            rbox_stroke(x, y, 12.0, 12.0, 8.5, 7.0, 2.2, 0.95).min(seg(x, y, 9.2, 5.2, 9.2, 18.8, 0.95))
        }
        IconKind::Calendar => rbox_stroke(x, y, 12.0, 13.0, 8.0, 7.0, 2.0, 0.95)
            .min(seg(x, y, 4.2, 9.5, 19.8, 9.5, 0.9))
            .min(seg(x, y, 8.0, 3.8, 8.0, 6.8, 0.95))
            .min(seg(x, y, 16.0, 3.8, 16.0, 6.8, 0.95)),
        IconKind::Import => seg(x, y, 12.0, 4.5, 12.0, 15.0, s)
            .min(seg(x, y, 8.0, 11.2, 12.0, 15.2, s))
            .min(seg(x, y, 16.0, 11.2, 12.0, 15.2, s))
            .min(seg(x, y, 5.0, 19.0, 19.0, 19.0, s)),
        IconKind::Settings => {
            let mut d = circle_ring(x, y, 12.0, 12.0, 5.4, 1.15).max(-disc(x, y, 12.0, 12.0, 2.6));
            for i in 0..6 {
                let a = (i as f32) * std::f32::consts::PI / 3.0;
                let (cx, cy) = (12.0 + a.cos() * 7.2, 12.0 + a.sin() * 7.2);
                d = d.min(disc(x, y, cx, cy, 1.55));
            }
            d.max(-disc(x, y, 12.0, 12.0, 2.6))
        }
        IconKind::Sliders => seg(x, y, 4.5, 7.0, 19.5, 7.0, 0.95)
            .min(disc(x, y, 9.5, 7.0, 2.1))
            .min(seg(x, y, 4.5, 12.0, 19.5, 12.0, 0.95))
            .min(disc(x, y, 15.0, 12.0, 2.1))
            .min(seg(x, y, 4.5, 17.0, 19.5, 17.0, 0.95))
            .min(disc(x, y, 10.5, 17.0, 2.1)),
        IconKind::ArrowUp => seg(x, y, 12.0, 19.0, 12.0, 5.5, 1.1)
            .min(seg(x, y, 6.5, 11.0, 12.0, 5.5, 1.1))
            .min(seg(x, y, 17.5, 11.0, 12.0, 5.5, 1.1)),
        IconKind::BubbleAlert => rbox(x, y, 12.0, 11.0, 8.0, 6.5, 2.5)
            .max(-seg(x, y, 12.0, 7.5, 12.0, 11.5, 1.1))
            .max(-disc(x, y, 12.0, 14.2, 1.15)),
        IconKind::EnvelopeBadge => rbox_stroke(x, y, 12.0, 13.0, 8.2, 5.8, 1.8, 0.95)
            .min(seg(x, y, 4.2, 8.0, 12.0, 13.2, 0.9))
            .min(seg(x, y, 19.8, 8.0, 12.0, 13.2, 0.9)),
        IconKind::Back => seg(x, y, 19.0, 12.0, 6.0, 12.0, s)
            .min(seg(x, y, 11.0, 6.5, 5.5, 12.0, s))
            .min(seg(x, y, 11.0, 17.5, 5.5, 12.0, s)),
        IconKind::Search => circle_ring(x, y, 10.5, 10.5, 5.8, s).min(seg(x, y, 15.0, 15.0, 19.8, 19.8, s)),
        IconKind::Terminal | IconKind::Shell => rbox_stroke(x, y, 12.0, 12.0, 8.5, 7.0, 2.2, 0.95)
            .min(seg(x, y, 7.2, 9.2, 10.5, 12.0, 0.95))
            .min(seg(x, y, 10.5, 12.0, 7.2, 14.8, 0.95))
            .min(seg(x, y, 12.2, 14.8, 16.5, 14.8, 0.95)),
        IconKind::Folder => rbox_stroke(x, y, 12.0, 13.2, 8.5, 5.8, 1.8, 0.95)
            .min(seg(x, y, 3.8, 7.4, 9.5, 7.4, 0.95))
            .min(seg(x, y, 9.5, 7.4, 11.2, 9.2, 0.95)),
        IconKind::Paperclip => seg(x, y, 8.0, 13.0, 14.5, 6.5, 0.95)
            .min(seg(x, y, 14.5, 6.5, 18.0, 10.0, 0.95))
            .min(seg(x, y, 18.0, 10.0, 10.0, 18.0, 0.95))
            .min(seg(x, y, 10.0, 18.0, 6.5, 14.5, 0.95))
            .min(seg(x, y, 6.5, 14.5, 13.5, 7.5, 0.95)),
        IconKind::Send => seg(x, y, 4.5, 11.5, 19.5, 5.0, 0.95)
            .min(seg(x, y, 19.5, 5.0, 13.5, 19.5, 0.95))
            .min(seg(x, y, 4.5, 11.5, 10.8, 13.2, 0.95))
            .min(seg(x, y, 10.8, 13.2, 13.5, 19.5, 0.95))
            .min(seg(x, y, 10.8, 13.2, 19.2, 5.2, 0.9)),
        IconKind::Trash => seg(x, y, 5.0, 7.0, 19.0, 7.0, s)
            .min(seg(x, y, 9.5, 4.8, 14.5, 4.8, s))
            .min(rbox_stroke(x, y, 12.0, 13.5, 5.5, 6.2, 1.5, 0.95))
            .min(seg(x, y, 10.2, 10.2, 10.2, 16.5, 0.85))
            .min(seg(x, y, 13.8, 10.2, 13.8, 16.5, 0.85)),
        IconKind::Sparkles => {
            let star = |cx: f32, cy: f32, r: f32| {
                seg(x, y, cx - r, cy, cx + r, cy, 0.9)
                    .min(seg(x, y, cx, cy - r, cx, cy + r, 0.9))
                    .min(disc(x, y, cx, cy, r * 0.36))
            };
            star(11.0, 11.5, 6.2)
                .min(star(18.0, 6.2, 2.8))
                .min(star(17.5, 17.5, 2.3))
        }
        IconKind::ExternalLink => seg(x, y, 13.0, 5.0, 19.0, 5.0, s)
            .min(seg(x, y, 19.0, 5.0, 19.0, 11.0, s))
            .min(seg(x, y, 10.5, 13.5, 18.8, 5.2, s))
            .min(seg(x, y, 5.0, 8.0, 5.0, 19.0, 0.95))
            .min(seg(x, y, 5.0, 19.0, 16.0, 19.0, 0.95))
            .min(seg(x, y, 5.0, 8.0, 10.0, 8.0, 0.95))
            .min(seg(x, y, 16.0, 14.0, 16.0, 19.0, 0.95)),
        IconKind::Copy => rbox_stroke(x, y, 13.8, 13.8, 5.2, 5.8, 1.5, 0.95)
            .min(seg(x, y, 6.2, 14.5, 6.2, 5.8, 0.95))
            .min(seg(x, y, 6.2, 5.8, 14.5, 5.8, 0.95)),
        IconKind::Warning => seg(x, y, 12.0, 4.5, 20.0, 19.0, 0.95)
            .min(seg(x, y, 20.0, 19.0, 4.0, 19.0, 0.95))
            .min(seg(x, y, 4.0, 19.0, 12.0, 4.5, 0.95))
            .min(seg(x, y, 12.0, 9.5, 12.0, 14.0, 1.0))
            .min(disc(x, y, 12.0, 16.8, 1.1)),
        IconKind::Info => circle_ring(x, y, 12.0, 12.0, 8.2, 0.95)
            .min(seg(x, y, 12.0, 11.2, 12.0, 16.2, 1.05))
            .min(disc(x, y, 12.0, 8.0, 1.15)),
        IconKind::Question => circle_ring(x, y, 12.0, 12.0, 8.2, 0.95)
            .min(seg(x, y, 9.8, 9.2, 12.0, 7.6, 0.95))
            .min(seg(x, y, 12.0, 7.6, 14.4, 9.2, 0.95))
            .min(seg(x, y, 14.4, 9.2, 12.0, 12.2, 0.95))
            .min(seg(x, y, 12.0, 12.2, 12.0, 13.5, 0.95))
            .min(disc(x, y, 12.0, 16.4, 1.15)),
        IconKind::Clock => circle_ring(x, y, 12.0, 12.0, 8.2, 0.95)
            .min(seg(x, y, 12.0, 7.2, 12.0, 12.0, 1.0))
            .min(seg(x, y, 12.0, 12.0, 15.5, 14.2, 1.0)),
        IconKind::Filter => seg(x, y, 4.5, 6.5, 19.5, 6.5, s)
            .min(seg(x, y, 7.5, 12.0, 16.5, 12.0, s))
            .min(seg(x, y, 10.2, 17.5, 13.8, 17.5, s)),
        IconKind::Close => seg(x, y, 6.5, 6.5, 17.5, 17.5, s).min(seg(x, y, 17.5, 6.5, 6.5, 17.5, s)),
        IconKind::Refresh => {
            let ring = circle_ring(x, y, 12.0, 12.0, 7.2, 1.0).max((x - 15.8).min(9.5 - y));
            ring.min(seg(x, y, 15.5, 5.2, 19.2, 5.2, 1.0))
                .min(seg(x, y, 19.2, 5.2, 19.2, 8.9, 1.0))
        }
        IconKind::Claude => {
            let mut d = disc(x, y, 12.0, 12.0, 2.2);
            for i in 0..8 {
                let a = (i as f32) * std::f32::consts::PI / 4.0;
                d = d.min(seg(
                    x,
                    y,
                    12.0,
                    12.0,
                    12.0 + a.cos() * 7.8,
                    12.0 + a.sin() * 7.8,
                    0.95,
                ));
            }
            d
        }
        IconKind::Codex => {
            let mut d = f32::MAX;
            for i in 0..6 {
                let a0 = (i as f32) * std::f32::consts::PI / 3.0;
                let a1 = ((i + 1) as f32) * std::f32::consts::PI / 3.0;
                d = d.min(seg(
                    x,
                    y,
                    12.0 + a0.cos() * 7.8,
                    12.0 + a0.sin() * 7.8,
                    12.0 + a1.cos() * 7.8,
                    12.0 + a1.sin() * 7.8,
                    0.95,
                ));
            }
            d.min(disc(x, y, 12.0, 12.0, 2.3))
        }
        IconKind::Grok => circle_ring(x, y, 12.0, 12.0, 6.6, 1.05).min(seg(x, y, 5.2, 18.8, 18.8, 5.2, 1.15)),
        IconKind::Antigravity => seg(x, y, 12.0, 4.5, 19.5, 18.5, 1.05)
            .min(seg(x, y, 19.5, 18.5, 4.5, 18.5, 1.05))
            .min(seg(x, y, 4.5, 18.5, 12.0, 4.5, 1.05))
            .min(disc(x, y, 12.0, 13.8, 2.0)),
        IconKind::ArrowDown => seg(x, y, 12.0, 5.0, 12.0, 18.5, 1.1)
            .min(seg(x, y, 6.5, 13.0, 12.0, 18.5, 1.1))
            .min(seg(x, y, 17.5, 13.0, 12.0, 18.5, 1.1)),
        IconKind::TextFormatSize => seg(x, y, 4.0, 18.0, 8.5, 6.0, 1.0)
            .min(seg(x, y, 8.5, 6.0, 13.0, 18.0, 1.0))
            .min(seg(x, y, 5.8, 14.0, 11.2, 14.0, 0.9))
            .min(seg(x, y, 15.0, 18.0, 17.5, 10.5, 0.9))
            .min(seg(x, y, 17.5, 10.5, 20.0, 18.0, 0.9)),
        IconKind::MinusCircle => {
            circle_ring(x, y, 12.0, 12.0, 8.2, 0.95).min(seg(x, y, 8.0, 12.0, 16.0, 12.0, 1.05))
        }
        IconKind::TrayFull => rbox_stroke(x, y, 12.0, 13.5, 8.2, 5.5, 1.8, 0.95)
            .min(seg(x, y, 7.5, 10.5, 16.5, 10.5, 0.9))
            .min(seg(x, y, 7.5, 13.5, 16.5, 13.5, 0.9)),
        IconKind::CheckCircle => circle_ring(x, y, 12.0, 12.0, 8.2, 0.95)
            .min(seg(x, y, 8.0, 12.2, 10.8, 15.0, 1.0))
            .min(seg(x, y, 10.8, 15.0, 16.2, 9.2, 1.0)),
        IconKind::StopCircle => {
            circle_ring(x, y, 12.0, 12.0, 8.2, 0.95).min(rbox(x, y, 12.0, 12.0, 3.6, 3.6, 0.9))
        }
        IconKind::PauseCircle => circle_ring(x, y, 12.0, 12.0, 8.2, 0.95)
            .min(rbox(x, y, 9.8, 12.0, 1.2, 3.8, 0.6))
            .min(rbox(x, y, 14.2, 12.0, 1.2, 3.8, 0.6)),
        IconKind::Repeat => rbox_stroke(x, y, 12.0, 12.0, 7.5, 5.0, 2.2, 0.95)
            .min(seg(x, y, 15.0, 4.8, 17.8, 7.0, 0.95))
            .min(seg(x, y, 9.0, 19.2, 6.2, 17.0, 0.95)),
        IconKind::Square => rbox_stroke(x, y, 12.0, 12.0, 7.2, 7.2, 2.0, 0.95),
        IconKind::Bubbles => rbox_stroke(x, y, 9.5, 10.0, 5.8, 4.5, 1.8, 0.9)
            .min(rbox_stroke(x, y, 15.0, 14.5, 5.2, 4.0, 1.6, 0.9)),
        IconKind::Wrench => seg(x, y, 6.0, 18.0, 16.5, 7.5, 1.35)
            .min(circle_ring(x, y, 17.2, 6.8, 3.2, 1.05))
            .min(disc(x, y, 6.2, 17.8, 2.0)),
        IconKind::FileText => rbox_stroke(x, y, 12.0, 12.0, 6.2, 8.0, 1.8, 0.95)
            .min(seg(x, y, 8.6, 9.0, 15.4, 9.0, 0.9))
            .min(seg(x, y, 8.6, 12.5, 15.4, 12.5, 0.9))
            .min(seg(x, y, 8.6, 16.0, 13.4, 16.0, 0.9)),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_icon_rasterizes_non_empty_antialiased_coverage() {
        for kind in IconKind::ALL {
            let rgba = rasterize_icon_rgba(kind, 32);
            assert_eq!(rgba.len(), 32 * 32 * 4);
            let lit = rgba.as_chunks::<4>().0.iter().filter(|px| px[3] > 32).count();
            assert!(lit > 20, "icon {kind:?} rendered too few pixels ({lit})");
        }
    }
}
