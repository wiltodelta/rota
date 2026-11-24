//! GPU primitive instance layout and ergonomic quad/mask/bitmap constructors.

use crate::color::Color;
use crate::geometry::{Corners, Point, Rect};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u32)]
pub enum PrimitiveKind {
    Quad = 0,
    Mask = 1,
    ColorBitmap = 2,
}

pub const BITMAP_FLAG_PREMULTIPLIED: u32 = 1;
pub const MASK_FLAG_ICON: u32 = 2;

/// 16-byte aligned instance payload read directly by `shader.wgsl` storage buffer.
#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct GpuPrimitive {
    pub bounds: [f32; 4],
    pub clip_rect: [f32; 4],
    pub corners: [f32; 4],
    pub fill_color: [f32; 4],
    pub border_color: [f32; 4],
    pub shadow_color: [f32; 4],
    pub uv_rect: [f32; 4],
    pub params: [f32; 4],
    pub kind_flags: [u32; 4],
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct QuadSpec {
    pub bounds: Rect,
    pub corners: Corners,
    pub fill: Color,
    pub border_width: f32,
    pub border_color: Color,
    pub shadow_blur: f32,
    pub shadow_offset: Point,
    pub shadow_color: Color,
}

impl QuadSpec {
    #[inline]
    pub const fn solid(bounds: Rect, fill: Color) -> Self {
        Self {
            bounds,
            corners: Corners::ZERO,
            fill,
            border_width: 0.0,
            border_color: Color::TRANSPARENT,
            shadow_blur: 0.0,
            shadow_offset: Point::ZERO,
            shadow_color: Color::TRANSPARENT,
        }
    }

    #[inline]
    pub const fn rounded(mut self, radius: f32) -> Self {
        self.corners = Corners::all(radius);
        self
    }

    #[inline]
    pub const fn with_corners(mut self, corners: Corners) -> Self {
        self.corners = corners;
        self
    }

    #[inline]
    pub const fn border(mut self, width: f32, color: Color) -> Self {
        self.border_width = width;
        self.border_color = color;
        self
    }

    #[inline]
    pub const fn shadow(mut self, blur: f32, offset: Point, color: Color) -> Self {
        self.shadow_blur = blur;
        self.shadow_offset = offset;
        self.shadow_color = color;
        self
    }

    #[inline]
    pub fn into_gpu(self, clip: Rect) -> GpuPrimitive {
        GpuPrimitive {
            bounds: self.bounds.to_xywh(),
            clip_rect: clip.to_clip_array(),
            corners: self.corners.to_array(),
            fill_color: self.fill.to_linear_rgba(),
            border_color: self.border_color.to_linear_rgba(),
            shadow_color: self.shadow_color.to_linear_rgba(),
            uv_rect: [0.0, 0.0, 1.0, 1.0],
            params: [
                self.border_width,
                self.shadow_blur,
                self.shadow_offset.x,
                self.shadow_offset.y,
            ],
            kind_flags: [PrimitiveKind::Quad as u32, 0, 0, 0],
        }
    }
}

impl GpuPrimitive {
    #[inline]
    pub fn mask(bounds: Rect, uv_rect: [f32; 4], color: Color, clip: Rect) -> Self {
        Self {
            bounds: bounds.to_xywh(),
            clip_rect: clip.to_clip_array(),
            corners: [0.0; 4],
            fill_color: color.to_linear_rgba(),
            border_color: [0.0; 4],
            shadow_color: [0.0; 4],
            uv_rect,
            params: [0.0; 4],
            kind_flags: [PrimitiveKind::Mask as u32, 0, 0, 0],
        }
    }

    #[inline]
    pub fn icon_mask(bounds: Rect, uv_rect: [f32; 4], color: Color, clip: Rect) -> Self {
        let mut p = Self::mask(bounds, uv_rect, color, clip);
        p.kind_flags[1] = MASK_FLAG_ICON;
        p
    }

    #[inline]
    pub fn color_bitmap(
        bounds: Rect,
        uv_rect: [f32; 4],
        corners: Corners,
        tint: Color,
        premultiplied: bool,
        clip: Rect,
    ) -> Self {
        let flags = if premultiplied {
            BITMAP_FLAG_PREMULTIPLIED
        } else {
            0
        };
        Self {
            bounds: bounds.to_xywh(),
            clip_rect: clip.to_clip_array(),
            corners: corners.to_array(),
            fill_color: tint.to_linear_rgba(),
            border_color: [0.0; 4],
            shadow_color: [0.0; 4],
            uv_rect,
            params: [0.0; 4],
            kind_flags: [PrimitiveKind::ColorBitmap as u32, flags, 0, 0],
        }
    }
}

/// Uniform globals buffer layout (`32` bytes / 16-byte aligned).
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct GpuGlobals {
    pub viewport_size: [f32; 2],
    pub scale_factor: f32,
    pub _pad: f32,
}

/// Safe view of `#[repr(C)]` POD slices as raw bytes for `wgpu::Queue::write_buffer`.
pub fn as_byte_slice<T: Copy>(items: &[T]) -> &[u8] {
    let byte_len = std::mem::size_of_val(items);
    if byte_len == 0 {
        return &[];
    }
    // SAFETY: `T` in this module (`GpuPrimitive`, `GpuGlobals`) is `#[repr(C)]` plain numeric arrays
    // with zero uninitialized padding bytes.
    unsafe { std::slice::from_raw_parts(items.as_ptr().cast::<u8>(), byte_len) }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn gpu_primitive_layout_matches_wgsl_alignment() {
        assert_eq!(std::mem::size_of::<GpuPrimitive>(), 144);
        assert_eq!(std::mem::align_of::<GpuPrimitive>(), 4);
        assert_eq!(std::mem::size_of::<GpuGlobals>(), 16);
    }
}
