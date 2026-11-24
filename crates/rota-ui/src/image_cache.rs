//! Zero-disk-check-per-frame PNG & JPEG decoder and GPU color-atlas image cache.

use std::collections::HashMap;
use std::io::Cursor;
use std::path::{Path, PathBuf};

use crate::atlas::{AtlasRegion, TextureAtlas};
use crate::geometry::Size;

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct ResolvedImage {
    pub pixel_width: u32,
    pub pixel_height: u32,
    pub uv_rect: [f32; 4],
}

impl ResolvedImage {
    /// Returns aspect-preserving logical size fitting inside `max_box`.
    #[inline]
    pub fn fit_within(self, max_box: Size, scale_factor: f32) -> Size {
        let natural_w = (self.pixel_width as f32) / scale_factor.max(1.0);
        let natural_h = (self.pixel_height as f32) / scale_factor.max(1.0);
        if natural_w <= 0.0 || natural_h <= 0.0 {
            return Size::ZERO;
        }
        let scale = (max_box.width / natural_w)
            .min(max_box.height / natural_h)
            .min(1.0);
        Size::new(natural_w * scale, natural_h * scale)
    }
}

#[derive(Debug, Clone)]
enum CachedEntry {
    Loaded {
        region: AtlasRegion,
        rgba: Vec<u8>,
        width: u32,
        height: u32,
    },
    Failed,
}

/// Caches decoded images in memory and in the `color_atlas` with zero main-thread disk `stat`
/// per frame once an entry has been resolved.
#[derive(Debug)]
pub struct ImageCache {
    max_dimension: u32,
    by_path: HashMap<PathBuf, CachedEntry>,
    by_key: HashMap<String, CachedEntry>,
}

impl Default for ImageCache {
    fn default() -> Self {
        Self::new(1024)
    }
}

impl ImageCache {
    pub fn new(max_dimension: u32) -> Self {
        Self {
            max_dimension: max_dimension.clamp(16, 2048),
            by_path: HashMap::new(),
            by_key: HashMap::new(),
        }
    }

    /// Invalidates a specific path so the next render reloads modified disk content.
    pub fn invalidate_path(&mut self, path: &Path) {
        self.by_path.remove(path);
    }

    pub fn clear(&mut self) {
        self.by_path.clear();
        self.by_key.clear();
    }

    /// Loads or retrieves a cached image by file path without touching disk on subsequent frames.
    pub fn resolve_path(&mut self, path: &Path, color_atlas: &mut TextureAtlas) -> Option<ResolvedImage> {
        if !self.by_path.contains_key(path) {
            let entry = match std::fs::read(path) {
                Ok(bytes) => self.decode_to_entry(&bytes, color_atlas),
                Err(_) => CachedEntry::Failed,
            };
            self.by_path.insert(path.to_path_buf(), entry);
        }
        let entry = self.by_path.get_mut(path)?;
        Self::materialize_entry(entry, color_atlas)
    }

    /// Loads or retrieves an in-memory PNG/JPEG image keyed by `cache_key`.
    pub fn resolve_bytes(
        &mut self,
        cache_key: &str,
        bytes: &[u8],
        color_atlas: &mut TextureAtlas,
    ) -> Option<ResolvedImage> {
        if !self.by_key.contains_key(cache_key) {
            let entry = self.decode_to_entry(bytes, color_atlas);
            self.by_key.insert(cache_key.to_string(), entry);
        }
        let entry = self.by_key.get_mut(cache_key)?;
        Self::materialize_entry(entry, color_atlas)
    }

    fn decode_to_entry(&self, bytes: &[u8], color_atlas: &mut TextureAtlas) -> CachedEntry {
        let Some((w, h, rgba)) = decode_image_rgba8(bytes, self.max_dimension) else {
            return CachedEntry::Failed;
        };
        let Some(region) = color_atlas.allocate_and_upload(w, h, rgba.clone()) else {
            return CachedEntry::Failed;
        };
        CachedEntry::Loaded {
            region,
            rgba,
            width: w,
            height: h,
        }
    }

    fn materialize_entry(entry: &mut CachedEntry, color_atlas: &mut TextureAtlas) -> Option<ResolvedImage> {
        match entry {
            CachedEntry::Failed => None,
            CachedEntry::Loaded {
                region,
                rgba,
                width,
                height,
            } => {
                if region.generation != color_atlas.generation() {
                    *region = color_atlas.allocate_and_upload(*width, *height, rgba.clone())?;
                }
                Some(ResolvedImage {
                    pixel_width: *width,
                    pixel_height: *height,
                    uv_rect: color_atlas.uv_for(*region),
                })
            }
        }
    }
}

/// Decodes PNG or JPEG bytes to straight sRGB RGBA8, downscaling if larger than `max_dim`.
pub fn decode_image_rgba8(bytes: &[u8], max_dim: u32) -> Option<(u32, u32, Vec<u8>)> {
    let (w, h, rgba) = if bytes.starts_with(&[0x89, b'P', b'N', b'G', 0x0D, 0x0A, 0x1A, 0x0A]) {
        decode_png(bytes)?
    } else {
        decode_jpeg(bytes).or_else(|| decode_png(bytes))?
    };
    if w == 0 || h == 0 {
        return None;
    }
    if w <= max_dim && h <= max_dim {
        return Some((w, h, rgba));
    }
    let scale = (max_dim as f32 / w as f32).min(max_dim as f32 / h as f32);
    let dst_w = ((w as f32 * scale).round() as u32).max(1);
    let dst_h = ((h as f32 * scale).round() as u32).max(1);
    Some((dst_w, dst_h, downscale_bilinear(&rgba, w, h, dst_w, dst_h)))
}

fn decode_png(bytes: &[u8]) -> Option<(u32, u32, Vec<u8>)> {
    let mut decoder = png::Decoder::new(Cursor::new(bytes));
    decoder.set_transformations(png::Transformations::EXPAND | png::Transformations::STRIP_16);
    let mut reader = decoder.read_info().ok()?;
    let mut buf = vec![0u8; reader.output_buffer_size()];
    let info = reader.next_frame(&mut buf).ok()?;
    let raw = &buf[..info.buffer_size()];
    let w = info.width;
    let h = info.height;
    let px_count = (w as usize).checked_mul(h as usize)?;
    let rgba = match info.color_type {
        png::ColorType::Rgba => raw.to_vec(),
        png::ColorType::Rgb => {
            let mut out = Vec::with_capacity(px_count * 4);
            for &[r, g, b] in raw.as_chunks::<3>().0 {
                out.extend_from_slice(&[r, g, b, 255]);
            }
            out
        }
        png::ColorType::GrayscaleAlpha => {
            let mut out = Vec::with_capacity(px_count * 4);
            for &[g, a] in raw.as_chunks::<2>().0 {
                out.extend_from_slice(&[g, g, g, a]);
            }
            out
        }
        png::ColorType::Grayscale => {
            let mut out = Vec::with_capacity(px_count * 4);
            for &g in raw {
                out.extend_from_slice(&[g, g, g, 255]);
            }
            out
        }
        png::ColorType::Indexed => return None,
    };
    Some((w, h, rgba))
}

fn decode_jpeg(bytes: &[u8]) -> Option<(u32, u32, Vec<u8>)> {
    let mut decoder = jpeg_decoder::Decoder::new(Cursor::new(bytes));
    let pixels = decoder.decode().ok()?;
    let info = decoder.info()?;
    let w = u32::from(info.width);
    let h = u32::from(info.height);
    let px_count = (w as usize).checked_mul(h as usize)?;
    let rgba = match info.pixel_format {
        jpeg_decoder::PixelFormat::RGB24 => {
            let mut out = Vec::with_capacity(px_count * 4);
            for &[r, g, b] in pixels.as_chunks::<3>().0 {
                out.extend_from_slice(&[r, g, b, 255]);
            }
            out
        }
        jpeg_decoder::PixelFormat::L8 => {
            let mut out = Vec::with_capacity(px_count * 4);
            for &g in &pixels {
                out.extend_from_slice(&[g, g, g, 255]);
            }
            out
        }
        jpeg_decoder::PixelFormat::CMYK32 => {
            let mut out = Vec::with_capacity(px_count * 4);
            for &[c, m, y, k_raw] in pixels.as_chunks::<4>().0 {
                let k = u16::from(k_raw);
                let r = ((255 - u16::from(c)) * (255 - k) / 255) as u8;
                let g = ((255 - u16::from(m)) * (255 - k) / 255) as u8;
                let b = ((255 - u16::from(y)) * (255 - k) / 255) as u8;
                out.extend_from_slice(&[r, g, b, 255]);
            }
            out
        }
        jpeg_decoder::PixelFormat::L16 => return None,
    };
    Some((w, h, rgba))
}

fn downscale_bilinear(src: &[u8], sw: u32, sh: u32, dw: u32, dh: u32) -> Vec<u8> {
    let mut dst = vec![0u8; (dw * dh * 4) as usize];
    for y in 0..dh {
        let sy = (((y as f32 + 0.5) * sh as f32 / dh as f32) - 0.5).clamp(0.0, (sh - 1) as f32);
        let y0 = sy.floor() as u32;
        let y1 = (y0 + 1).min(sh - 1);
        let wy = sy - y0 as f32;
        for x in 0..dw {
            let sx = (((x as f32 + 0.5) * sw as f32 / dw as f32) - 0.5).clamp(0.0, (sw - 1) as f32);
            let x0 = sx.floor() as u32;
            let x1 = (x0 + 1).min(sw - 1);
            let wx = sx - x0 as f32;

            let i00 = ((y0 * sw + x0) * 4) as usize;
            let i10 = ((y0 * sw + x1) * 4) as usize;
            let i01 = ((y1 * sw + x0) * 4) as usize;
            let i11 = ((y1 * sw + x1) * 4) as usize;
            let out_i = ((y * dw + x) * 4) as usize;
            for ch in 0..4 {
                let top = src[i00 + ch] as f32 * (1.0 - wx) + src[i10 + ch] as f32 * wx;
                let bot = src[i01 + ch] as f32 * (1.0 - wx) + src[i11 + ch] as f32 * wx;
                dst[out_i + ch] = (top * (1.0 - wy) + bot * wy).round() as u8;
            }
        }
    }
    dst
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn png_decode_downscale_and_atlas_caching() {
        let mut png_bytes = Vec::new();
        {
            let mut enc = png::Encoder::new(&mut png_bytes, 64, 32);
            enc.set_color(png::ColorType::Rgba);
            enc.set_depth(png::BitDepth::Eight);
            let mut writer = enc.write_header().expect("header");
            let pixels = vec![200u8; 64 * 32 * 4];
            writer.write_image_data(&pixels).expect("write");
        }
        let mut atlas = TextureAtlas::new(256, 256);
        let mut cache = ImageCache::new(32);
        let resolved = cache
            .resolve_bytes("sample", &png_bytes, &mut atlas)
            .expect("decode");
        assert_eq!(resolved.pixel_width, 32);
        assert_eq!(resolved.pixel_height, 16);
    }
}
