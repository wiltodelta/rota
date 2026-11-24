//! CoreText font lookup, UTF-8/UTF-16 mapping, attributed string builders, and `CGBitmapContext` glyph rasterizer.

#![cfg(target_os = "macos")]

use std::ffi::c_void;
use std::ops::Range;
use std::ptr::NonNull;

use objc2_core_foundation::{
    CFAttributedString, CFMutableAttributedString, CFRange, CFRetained, CFString, CGFloat, CGPoint, CGRect,
    CGSize,
};
use objc2_core_graphics::{CGBitmapContextCreate, CGColorSpace, CGContext, CGGlyph, CGImageAlphaInfo};
use objc2_core_text::{
    CTFont, CTFontOrientation, CTFontSymbolicTraits, CTFontUIFontType, kCTFontAttributeName,
};

use crate::geometry::{Point, Size};
use crate::text::{FontFamily, FontStyle, FontWeight};
use crate::text_macos::RasterizedGlyph;

pub(crate) struct Utf16Map {
    pub boundaries: Vec<(usize, usize)>,
    pub utf16_len: usize,
}

impl Utf16Map {
    pub fn build(s: &str) -> Self {
        let mut boundaries = Vec::with_capacity(s.len() + 1);
        let mut u16_off = 0usize;
        for (b_off, ch) in s.char_indices() {
            boundaries.push((b_off, u16_off));
            u16_off += ch.len_utf16();
        }
        boundaries.push((s.len(), u16_off));
        Self {
            boundaries,
            utf16_len: u16_off,
        }
    }

    pub fn utf8_to_utf16(&self, byte_off: usize) -> usize {
        match self.boundaries.binary_search_by_key(&byte_off, |&(b, _)| b) {
            Ok(i) => self.boundaries[i].1,
            Err(i) => self.boundaries[i.saturating_sub(1)].1,
        }
    }

    pub fn utf16_to_utf8(&self, u16_off: usize) -> usize {
        match self.boundaries.binary_search_by_key(&u16_off, |&(_, u)| u) {
            Ok(i) => self.boundaries[i].0,
            Err(i) => self.boundaries[i.saturating_sub(1)].0,
        }
    }
}

pub(crate) fn build_attributed_segment(
    seg_str: &str,
    seg_byte_start: usize,
    map: &Utf16Map,
    span_slices: &[(Range<usize>, usize, u32)],
    fonts: &[CFRetained<CTFont>],
) -> CFRetained<CFAttributedString> {
    let mutable = CFMutableAttributedString::new(None, 0).expect("CFMutableAttributedString");
    let cf_text = CFString::from_str(seg_str);
    // SAFETY: replacing `(0, 0)` on a newly created mutable attributed string.
    unsafe {
        CFMutableAttributedString::replace_string(
            Some(&mutable),
            CFRange {
                location: 0,
                length: 0,
            },
            Some(&cf_text),
        );
    }
    let seg_byte_end = seg_byte_start + seg_str.len();
    for (range, _, font_id) in span_slices {
        let s = range.start.max(seg_byte_start);
        let e = range.end.min(seg_byte_end);
        if s >= e {
            continue;
        }
        let u16_s = map.utf8_to_utf16(s - seg_byte_start);
        let u16_e = map.utf8_to_utf16(e - seg_byte_start);
        if u16_e > u16_s {
            let ct_font = &fonts[*font_id as usize];
            // SAFETY: `u16_s..u16_e` is within `mutable` and `kCTFontAttributeName` expects `CTFont`.
            unsafe {
                CFMutableAttributedString::set_attribute(
                    Some(&mutable),
                    CFRange {
                        location: u16_s as isize,
                        length: (u16_e - u16_s) as isize,
                    },
                    Some(kCTFontAttributeName),
                    Some(ct_font.as_ref()),
                );
            }
        }
    }
    CFAttributedString::new_copy(None, Some(&mutable)).expect("CFAttributedString copy")
}

pub(crate) fn single_font_attr(text: &str, font: &CTFont) -> CFRetained<CFAttributedString> {
    let mutable = CFMutableAttributedString::new(None, 0).expect("CFMutableAttributedString");
    let cf_text = CFString::from_str(text);
    let u16_len = text.encode_utf16().count() as isize;
    // SAFETY: valid string & font attribute.
    unsafe {
        CFMutableAttributedString::replace_string(
            Some(&mutable),
            CFRange {
                location: 0,
                length: 0,
            },
            Some(&cf_text),
        );
        CFMutableAttributedString::set_attribute(
            Some(&mutable),
            CFRange {
                location: 0,
                length: u16_len,
            },
            Some(kCTFontAttributeName),
            Some(font.as_ref()),
        );
    }
    CFAttributedString::new_copy(None, Some(&mutable)).expect("CFAttributedString copy")
}

pub(crate) fn create_ct_font(
    family: FontFamily,
    weight: FontWeight,
    style: FontStyle,
    pt: CGFloat,
) -> CFRetained<CTFont> {
    let candidates: &[(&str, &str)] = match (family, weight, style) {
        (FontFamily::UiSans, FontWeight::Regular, FontStyle::Normal) => &[
            ("IBMPlexSans-Regular", "IBMPlexSans"),
            ("IBMPlexSans", "IBMPlexSans"),
        ],
        (FontFamily::UiSans, FontWeight::Regular, FontStyle::Italic) => {
            &[("IBMPlexSans-Italic", "IBMPlexSans")]
        }
        (FontFamily::UiSans, FontWeight::Medium | FontWeight::Semibold, FontStyle::Normal) => &[
            ("IBMPlexSans-SmBld", "IBMPlexSans"),
            ("IBMPlexSans-SemiBold", "IBMPlexSans"),
        ],
        (FontFamily::UiSans, FontWeight::Medium | FontWeight::Semibold, FontStyle::Italic) => &[
            ("IBMPlexSans-SmBldItalic", "IBMPlexSans"),
            ("IBMPlexSans-SemiBoldItalic", "IBMPlexSans"),
        ],
        (FontFamily::UiSans, FontWeight::Bold, FontStyle::Normal) => &[("IBMPlexSans-Bold", "IBMPlexSans")],
        (FontFamily::UiSans, FontWeight::Bold, FontStyle::Italic) => {
            &[("IBMPlexSans-BoldItalic", "IBMPlexSans")]
        }
        (FontFamily::Mono, FontWeight::Regular, FontStyle::Normal) => &[
            ("JetBrainsMono-Regular", "JetBrainsMono"),
            ("SFMono-Regular", "SFMono"),
            ("Menlo-Regular", "Menlo"),
        ],
        (FontFamily::Mono, FontWeight::Regular, FontStyle::Italic) => &[
            ("JetBrainsMono-Italic", "JetBrainsMono"),
            ("Menlo-Italic", "Menlo"),
        ],
        (FontFamily::Mono, _, FontStyle::Normal) => &[
            ("JetBrainsMono-Bold", "JetBrainsMono"),
            ("SFMono-Bold", "SFMono"),
            ("Menlo-Bold", "Menlo"),
        ],
        (FontFamily::Mono, _, FontStyle::Italic) => &[
            ("JetBrainsMono-BoldItalic", "JetBrainsMono"),
            ("Menlo-BoldItalic", "Menlo"),
        ],
        (FontFamily::System, _, _) => &[],
    };

    for &(name, prefix) in candidates {
        let cf = CFString::from_str(name);
        // SAFETY: `cf` is valid.
        let font = unsafe { CTFont::with_name(&cf, pt, std::ptr::null()) };
        let actual = unsafe { font.post_script_name() }.to_string();
        if actual.starts_with(prefix) {
            return font;
        }
    }

    let ui_type = if matches!(weight, FontWeight::Semibold | FontWeight::Bold) {
        CTFontUIFontType::EmphasizedSystem
    } else {
        CTFontUIFontType::System
    };
    // SAFETY: `CTFont::new_ui_font_for_language` is the official CoreText system UI font factory.
    let base = unsafe { CTFont::new_ui_font_for_language(ui_type, pt, None) }.unwrap_or_else(|| {
        let fallback = CFString::from_str("HelveticaNeue");
        unsafe { CTFont::with_name(&fallback, pt, std::ptr::null()) }
    });
    if style != FontStyle::Italic {
        return base;
    }
    let traits = CTFontSymbolicTraits::TraitItalic;
    // SAFETY: copying italic trait onto `base`.
    unsafe { base.copy_with_symbolic_traits(pt, std::ptr::null(), traits, traits) }.unwrap_or(base)
}

pub(crate) fn ct_font_point_size(font: &CTFont) -> f32 {
    unsafe extern "C-unwind" {
        fn CTFontGetSize(font: &CTFont) -> CGFloat;
    }
    // SAFETY: `font` is a valid `CTFont` reference.
    (unsafe { CTFontGetSize(font) }) as f32
}

pub(crate) fn rasterize_ct_glyph(
    font: &CTFont,
    glyph: CGGlyph,
    scale_tenths: u16,
    subpx_x: u8,
) -> Option<RasterizedGlyph> {
    let scale = f64::from(scale_tenths.max(10)) / 10.0;
    let shift_px = if subpx_x > 0 {
        f64::from(subpx_x.min(3)) * 0.25
    } else {
        0.0
    };
    let mut bbox = CGRect {
        origin: CGPoint { x: 0.0, y: 0.0 },
        size: CGSize {
            width: 0.0,
            height: 0.0,
        },
    };
    // SAFETY: `glyph` and `bbox` are valid single-element locals.
    unsafe {
        font.bounding_rects_for_glyphs(CTFontOrientation::Default, NonNull::from(&glyph), &mut bbox, 1);
    }
    if bbox.size.width <= 0.01 || bbox.size.height <= 0.01 {
        return Some(RasterizedGlyph {
            pixel_w: 0,
            pixel_h: 0,
            rgba: Vec::new(),
            offset_from_pen: Point::ZERO,
            pixel_offset: Point::ZERO,
            logical_size: Size::ZERO,
        });
    }

    let pad = 2i32;
    let min_x = (bbox.origin.x * scale + shift_px).floor() as i32 - pad;
    let max_x = ((bbox.origin.x + bbox.size.width) * scale + shift_px).ceil() as i32 + pad;
    let min_y = (bbox.origin.y * scale).floor() as i32 - pad;
    let max_y = ((bbox.origin.y + bbox.size.height) * scale).ceil() as i32 + pad;
    let bmp_w = (max_x - min_x).max(1) as u32;
    let bmp_h = (max_y - min_y).max(1) as u32;

    let mut rgba = vec![0u8; (bmp_w * bmp_h * 4) as usize];
    let space = CGColorSpace::new_device_rgb()?;
    // SAFETY: `rgba` lives across the entire `ctx` scope and matches `bmp_w * 4 * bmp_h`.
    let ctx = unsafe {
        CGBitmapContextCreate(
            rgba.as_mut_ptr().cast::<c_void>(),
            bmp_w as usize,
            bmp_h as usize,
            8,
            (bmp_w * 4) as usize,
            Some(&space),
            CGImageAlphaInfo::PremultipliedLast.0,
        )
    }?;

    CGContext::set_allows_antialiasing(Some(&ctx), true);
    CGContext::set_should_antialias(Some(&ctx), true);
    CGContext::set_should_smooth_fonts(Some(&ctx), false);
    CGContext::set_should_subpixel_position_fonts(Some(&ctx), true);
    CGContext::set_should_subpixel_quantize_fonts(Some(&ctx), true);
    CGContext::translate_ctm(Some(&ctx), f64::from(-min_x) + shift_px, f64::from(-min_y));
    CGContext::scale_ctm(Some(&ctx), scale, scale);
    CGContext::set_rgb_fill_color(Some(&ctx), 1.0, 1.0, 1.0, 1.0);

    let origin = CGPoint { x: 0.0, y: 0.0 };
    // SAFETY: `glyph` and `origin` are valid 1-element inputs for `ctx`.
    unsafe {
        font.draw_glyphs(NonNull::from(&glyph), NonNull::from(&origin), 1, &ctx);
    }

    let sf = scale as f32;
    Some(RasterizedGlyph {
        pixel_w: bmp_w,
        pixel_h: bmp_h,
        rgba,
        offset_from_pen: Point::new(min_x as f32 / sf, -(max_y as f32) / sf),
        pixel_offset: Point::new(min_x as f32, -(max_y as f32)),
        logical_size: Size::new(bmp_w as f32 / sf, bmp_h as f32 / sf),
    })
}
