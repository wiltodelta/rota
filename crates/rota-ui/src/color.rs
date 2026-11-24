//! RGBA color primitives, linear/sRGB conversions, and WCAG 2.1 contrast math.

/// An RGBA color stored in normalized sRGB `[0.0..=1.0]` space.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Color {
    pub r: f32,
    pub g: f32,
    pub b: f32,
    pub a: f32,
}

impl Color {
    pub const TRANSPARENT: Self = Self::new(0.0, 0.0, 0.0, 0.0);
    pub const BLACK: Self = Self::new(0.0, 0.0, 0.0, 1.0);
    pub const WHITE: Self = Self::new(1.0, 1.0, 1.0, 1.0);

    #[inline]
    pub const fn new(r: f32, g: f32, b: f32, a: f32) -> Self {
        Self { r, g, b, a }
    }

    /// Constructs an opaque color from a 24-bit `0xRRGGBB` integer.
    #[inline]
    pub const fn rgb_hex(hex: u32) -> Self {
        let r = ((hex >> 16) & 0xFF) as f32 / 255.0;
        let g = ((hex >> 8) & 0xFF) as f32 / 255.0;
        let b = (hex & 0xFF) as f32 / 255.0;
        Self { r, g, b, a: 1.0 }
    }

    /// Constructs a color from a 32-bit `0xRRGGBBAA` integer.
    #[inline]
    pub const fn rgba_hex(hex: u32) -> Self {
        let r = ((hex >> 24) & 0xFF) as f32 / 255.0;
        let g = ((hex >> 16) & 0xFF) as f32 / 255.0;
        let b = ((hex >> 8) & 0xFF) as f32 / 255.0;
        let a = (hex & 0xFF) as f32 / 255.0;
        Self { r, g, b, a }
    }

    #[inline]
    pub const fn rgba8(r: u8, g: u8, b: u8, a: u8) -> Self {
        Self {
            r: r as f32 / 255.0,
            g: g as f32 / 255.0,
            b: b as f32 / 255.0,
            a: a as f32 / 255.0,
        }
    }

    #[inline]
    pub const fn with_alpha(self, alpha: f32) -> Self {
        Self {
            r: self.r,
            g: self.g,
            b: self.b,
            a: alpha,
        }
    }

    #[inline]
    pub fn lerp(self, other: Self, t: f32) -> Self {
        let t = t.clamp(0.0, 1.0);
        Self {
            r: self.r + (other.r - self.r) * t,
            g: self.g + (other.g - self.g) * t,
            b: self.b + (other.b - self.b) * t,
            a: self.a + (other.a - self.a) * t,
        }
    }

    /// Alpha-composites `self` (foreground) over an opaque or translucent `background` in sRGB.
    #[inline]
    pub fn composite_over(self, background: Self) -> Self {
        let fg_a = self.a.clamp(0.0, 1.0);
        let bg_a = background.a.clamp(0.0, 1.0);
        let out_a = fg_a + bg_a * (1.0 - fg_a);
        if out_a <= f32::EPSILON {
            return Self::TRANSPARENT;
        }
        Self {
            r: (self.r * fg_a + background.r * bg_a * (1.0 - fg_a)) / out_a,
            g: (self.g * fg_a + background.g * bg_a * (1.0 - fg_a)) / out_a,
            b: (self.b * fg_a + background.b * bg_a * (1.0 - fg_a)) / out_a,
            a: out_a,
        }
    }

    #[inline]
    pub fn to_rgba8(self) -> [u8; 4] {
        [
            (self.r.clamp(0.0, 1.0) * 255.0).round() as u8,
            (self.g.clamp(0.0, 1.0) * 255.0).round() as u8,
            (self.b.clamp(0.0, 1.0) * 255.0).round() as u8,
            (self.a.clamp(0.0, 1.0) * 255.0).round() as u8,
        ]
    }

    /// Converts straight sRGB channels into straight linear-light `[r, g, b, a]` for `wgpu`.
    #[inline]
    pub fn to_linear_rgba(self) -> [f32; 4] {
        [
            srgb_to_linear(self.r),
            srgb_to_linear(self.g),
            srgb_to_linear(self.b),
            self.a.clamp(0.0, 1.0),
        ]
    }

    /// Converts to `wgpu::Color` in linear space for render-pass clear operations.
    #[inline]
    pub fn to_wgpu_color(self) -> wgpu::Color {
        let [r, g, b, a] = self.to_linear_rgba();
        let a = f64::from(a);
        wgpu::Color {
            r: f64::from(r) * a,
            g: f64::from(g) * a,
            b: f64::from(b) * a,
            a,
        }
    }

    /// Constructs an sRGB `Color` from linear-light channels.
    #[inline]
    pub fn from_linear_rgba(linear: [f32; 4]) -> Self {
        Self {
            r: linear_to_srgb(linear[0]),
            g: linear_to_srgb(linear[1]),
            b: linear_to_srgb(linear[2]),
            a: linear[3].clamp(0.0, 1.0),
        }
    }

    /// WCAG 2.1 relative luminance (`0.0` darkest black .. `1.0` diffuse white).
    #[inline]
    pub fn relative_luminance(self) -> f32 {
        let r = wcag_channel_luminance(self.r);
        let g = wcag_channel_luminance(self.g);
        let b = wcag_channel_luminance(self.b);
        0.2126 * r + 0.7152 * g + 0.0722 * b
    }
}

/// Computes the WCAG 2.1 contrast ratio (`1.0..=21.0`) of `fg` composited over `bg`.
#[inline]
pub fn contrast_ratio(fg: Color, bg: Color) -> f32 {
    let effective_fg = if fg.a < 1.0 { fg.composite_over(bg) } else { fg };
    let l1 = effective_fg.relative_luminance();
    let l2 = bg.relative_luminance();
    let (lighter, darker) = if l1 >= l2 { (l1, l2) } else { (l2, l1) };
    (lighter + 0.05) / (darker + 0.05)
}

#[inline]
pub fn srgb_to_linear(c: f32) -> f32 {
    let c = c.clamp(0.0, 1.0);
    if c <= 0.04045 {
        c / 12.92
    } else {
        ((c + 0.055) / 1.055).powf(2.4)
    }
}

#[inline]
pub fn linear_to_srgb(c: f32) -> f32 {
    let c = c.clamp(0.0, 1.0);
    if c <= 0.003_130_8 {
        c * 12.92
    } else {
        1.055 * c.powf(1.0 / 2.4) - 0.055
    }
}

#[inline]
fn wcag_channel_luminance(c: f32) -> f32 {
    let c = c.clamp(0.0, 1.0);
    if c <= 0.03928 {
        c / 12.92
    } else {
        ((c + 0.055) / 1.055).powf(2.4)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn srgb_linear_roundtrip_and_wcag_extremes() {
        let accent = Color::rgb_hex(0x1D5BD6);
        assert_eq!(accent.to_rgba8(), [0x1D, 0x5B, 0xD6, 0xFF]);

        let linear = accent.to_linear_rgba();
        let back = Color::from_linear_rgba(linear);
        assert!((back.r - accent.r).abs() < 1e-5);
        assert!((back.g - accent.g).abs() < 1e-5);
        assert!((back.b - accent.b).abs() < 1e-5);

        let bw = contrast_ratio(Color::BLACK, Color::WHITE);
        assert!((bw - 21.0).abs() < 0.01);
        assert!((contrast_ratio(accent, accent) - 1.0).abs() < 1e-5);
    }
}
