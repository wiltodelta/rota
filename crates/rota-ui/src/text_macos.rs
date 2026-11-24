//! macOS `CoreText` multi-line paragraph shaper (`CTTypesetter` / `CTLine` / `CTRun`).

#![cfg(target_os = "macos")]

use std::collections::HashMap;
use std::ops::Range;
use std::ptr::NonNull;

use objc2_core_foundation::{CFArray, CFDictionary, CFRange, CFRetained, CFString, CGFloat, CGPoint};
use objc2_core_graphics::CGGlyph;
use objc2_core_text::{
    CTFont, CTFontSymbolicTraits, CTLine, CTLineTruncationType, CTRun, CTTypesetter, kCTFontAttributeName,
};

use crate::font_macos::{
    Utf16Map, build_attributed_segment, create_ct_font, ct_font_point_size, rasterize_ct_glyph,
    single_font_attr,
};
use crate::geometry::{Point, Rect, Size};
use crate::text::{
    FontFamily, FontStyle, FontWeight, GlyphRasterKey, LineDecoration, PositionedGlyph, ShapedLine,
    ShapedParagraph, TextAlign, TextLayoutOpts, TextSpan,
};

pub struct RasterizedGlyph {
    pub pixel_w: u32,
    pub pixel_h: u32,
    pub rgba: Vec<u8>,
    pub offset_from_pen: Point,
    pub pixel_offset: Point,
    pub logical_size: Size,
}

pub struct MacFontBackend {
    fonts: Vec<CFRetained<CTFont>>,
    by_ps_and_size: HashMap<(String, u16), u32>,
    by_spec: HashMap<(FontFamily, FontWeight, FontStyle, u16), u32>,
}

impl MacFontBackend {
    pub fn new() -> Self {
        Self {
            fonts: Vec::with_capacity(32),
            by_ps_and_size: HashMap::new(),
            by_spec: HashMap::new(),
        }
    }

    pub fn resolved_postscript_name(
        &mut self,
        family: FontFamily,
        weight: FontWeight,
        style: FontStyle,
        size_pt: f32,
    ) -> String {
        let id = self.resolve_spec_font(family, weight, style, size_pt);
        let font = &self.fonts[id as usize];
        // SAFETY: `font` is a valid live `CTFont`.
        unsafe { font.post_script_name() }.to_string()
    }

    fn resolve_spec_font(
        &mut self,
        family: FontFamily,
        weight: FontWeight,
        style: FontStyle,
        size_pt: f32,
    ) -> u32 {
        let size_tenths = (size_pt.clamp(6.0, 200.0) * 10.0).round() as u16;
        let spec_key = (family, weight, style, size_tenths);
        if let Some(&id) = self.by_spec.get(&spec_key) {
            return id;
        }
        let pt = CGFloat::from(size_tenths) / 10.0;
        let ct_font = create_ct_font(family, weight, style, pt);
        let id = self.intern_ct_font(&ct_font, size_tenths);
        self.by_spec.insert(spec_key, id);
        id
    }

    fn intern_ct_font(&mut self, font: &CTFont, size_tenths: u16) -> u32 {
        // SAFETY: `font` is a valid `CTFont`.
        let ps_name = unsafe { font.post_script_name() }.to_string();
        let key = (ps_name, size_tenths);
        if let Some(&id) = self.by_ps_and_size.get(&key) {
            return id;
        }
        let pt = CGFloat::from(size_tenths) / 10.0;
        let empty = CTFontSymbolicTraits::empty();
        // SAFETY: `copy_with_symbolic_traits` clones `font` directly (including `.SFNS` & emoji fallbacks) without `.SFNS` name warnings.
        let owned = unsafe { font.copy_with_symbolic_traits(pt, std::ptr::null(), empty, empty) }
            .unwrap_or_else(|| {
                let cf_ps = CFString::from_str(&key.0);
                unsafe { CTFont::with_name(&cf_ps, pt, std::ptr::null()) }
            });
        let id = self.fonts.len() as u32;
        self.fonts.push(owned);
        self.by_ps_and_size.insert(key, id);
        id
    }

    pub fn rasterize_glyph(&self, key: GlyphRasterKey) -> Option<RasterizedGlyph> {
        let font = self.fonts.get(key.font_id as usize)?;
        rasterize_ct_glyph(font, key.glyph_id, key.scale_tenths, key.subpx_x)
    }

    pub fn shape_paragraph(
        &mut self,
        spans: &[TextSpan],
        opts: TextLayoutOpts,
        scale_factor: f32,
    ) -> ShapedParagraph {
        let sf = scale_factor.clamp(1.0, 4.0);
        let scale_tenths = (sf * 10.0).round() as u16;
        if spans.is_empty() {
            return ShapedParagraph {
                size: Size::ZERO,
                lines: Vec::new(),
                truncated: false,
                total_bytes: 0,
                scale_factor: sf,
            };
        }

        let mut full_text = String::new();
        let mut span_slices = Vec::with_capacity(spans.len());
        for (idx, span) in spans.iter().enumerate() {
            let start = full_text.len();
            full_text.push_str(&span.text);
            let font_id = self.resolve_spec_font(span.font, span.weight, span.style, span.size);
            span_slices.push((start..full_text.len(), idx, font_id));
        }

        let wrap_w = opts.max_width.filter(|&w| w.is_finite() && w > 1.0);
        let max_lines = opts.max_lines.unwrap_or(usize::MAX).max(1);
        let mut lines = Vec::new();
        let mut truncated = false;
        let mut y_cursor = 0.0f32;
        let mut max_line_w = 0.0f32;
        let raw_segments: Vec<&str> = full_text.split('\n').collect();
        let mut seg_byte_start = 0usize;

        for (seg_idx, seg_str) in raw_segments.iter().copied().enumerate() {
            let seg_byte_end = seg_byte_start + seg_str.len();
            let has_more_segments = seg_idx + 1 < raw_segments.len();

            if seg_str.is_empty() {
                let active_span = span_slices
                    .iter()
                    .find(|(r, _, _)| r.start <= seg_byte_start && seg_byte_start <= r.end)
                    .or_else(|| span_slices.last())
                    .expect("non-empty spans");
                let font = &self.fonts[active_span.2 as usize];
                let span_size = spans[active_span.1].size;
                // SAFETY: `font` is valid.
                let (asc, desc, lead) = unsafe {
                    (
                        font.ascent() as f32,
                        font.descent() as f32,
                        font.leading().max(0.0) as f32,
                    )
                };
                let lh = (asc + desc + lead).max(span_size * opts.line_height_factor);
                lines.push(ShapedLine {
                    byte_range: seg_byte_start..seg_byte_end,
                    y_top: y_cursor,
                    baseline_y: y_cursor + asc + (lh - (asc + desc)) * 0.5,
                    ascent: asc,
                    descent: desc,
                    height: lh,
                    width: 0.0,
                    x_offset: 0.0,
                    glyphs: Vec::new(),
                    decorations: Vec::new(),
                    caret_stops: vec![(seg_byte_start, 0.0)],
                });
                y_cursor += lh;
                if lines.len() >= max_lines && has_more_segments {
                    truncated = true;
                    break;
                }
                seg_byte_start = seg_byte_end + 1;
                continue;
            }

            let map = Utf16Map::build(seg_str);
            let attr = build_attributed_segment(seg_str, seg_byte_start, &map, &span_slices, &self.fonts);
            // SAFETY: `attr` is a valid `CFAttributedString`.
            let typesetter = unsafe { CTTypesetter::with_attributed_string(&attr) };
            let mut u16_pos = 0usize;

            while u16_pos < map.utf16_len {
                let at_line_cap = lines.len() + 1 >= max_lines;
                let suggested = if let Some(w) = wrap_w {
                    // SAFETY: `u16_pos` is within `attr` UTF-16 length.
                    let count = unsafe { typesetter.suggest_line_break(u16_pos as isize, f64::from(w)) };
                    (count.max(1) as usize).min(map.utf16_len - u16_pos)
                } else {
                    map.utf16_len - u16_pos
                };

                let overflows_cap = at_line_cap && (u16_pos + suggested < map.utf16_len || has_more_segments);
                let (ct_line, u16_end) = if overflows_cap {
                    truncated = true;
                    let rem_len = (map.utf16_len - u16_pos) as isize;
                    // SAFETY: valid range inside `typesetter`.
                    let full_rem = unsafe {
                        typesetter.line(CFRange {
                            location: u16_pos as isize,
                            length: rem_len,
                        })
                    };
                    if let Some(w) = wrap_w {
                        let ell_font_id = span_slices.last().map_or(0, |s| s.2);
                        let ell_attr = single_font_attr("…", &self.fonts[ell_font_id as usize]);
                        // SAFETY: valid `CFAttributedString` and `CTLine`.
                        let token = unsafe { CTLine::with_attributed_string(&ell_attr) };
                        let trunc = unsafe {
                            CTLine::truncated_line(
                                &full_rem,
                                f64::from(w),
                                CTLineTruncationType::End,
                                Some(&token),
                            )
                        };
                        (trunc.unwrap_or(full_rem), map.utf16_len)
                    } else {
                        (full_rem, map.utf16_len)
                    }
                } else {
                    // SAFETY: `u16_pos..u16_pos + suggested` is within `attr`.
                    let line = unsafe {
                        typesetter.line(CFRange {
                            location: u16_pos as isize,
                            length: suggested as isize,
                        })
                    };
                    (line, u16_pos + suggested)
                };

                let shaped_line = self.extract_shaped_line(
                    &ct_line,
                    u16_pos..u16_end,
                    seg_byte_start,
                    &map,
                    spans,
                    &span_slices,
                    opts,
                    scale_tenths,
                    y_cursor,
                );
                y_cursor += shaped_line.height;
                max_line_w = max_line_w.max(shaped_line.width);
                lines.push(shaped_line);
                u16_pos = u16_end;
                if truncated || lines.len() >= max_lines {
                    if u16_pos < map.utf16_len || has_more_segments {
                        truncated = true;
                    }
                    break;
                }
            }
            if lines.len() >= max_lines {
                break;
            }
            seg_byte_start = seg_byte_end + 1;
        }

        let container_w = wrap_w.unwrap_or(max_line_w).max(max_line_w);
        if opts.align != TextAlign::Left {
            for line in &mut lines {
                let slack = (container_w - line.width).max(0.0);
                line.x_offset = match opts.align {
                    TextAlign::Left => 0.0,
                    TextAlign::Center => slack * 0.5,
                    TextAlign::Right => slack,
                };
            }
        }
        ShapedParagraph {
            size: Size::new(max_line_w, y_cursor),
            lines,
            truncated,
            total_bytes: full_text.len(),
            scale_factor: sf,
        }
    }

    #[allow(clippy::too_many_arguments)]
    fn extract_shaped_line(
        &mut self,
        ct_line: &CTLine,
        u16_range: Range<usize>,
        seg_byte_start: usize,
        map: &Utf16Map,
        spans: &[TextSpan],
        span_slices: &[(Range<usize>, usize, u32)],
        opts: TextLayoutOpts,
        scale_tenths: u16,
        y_top: f32,
    ) -> ShapedLine {
        let (mut asc, mut desc, mut lead): (CGFloat, CGFloat, CGFloat) = (0.0, 0.0, 0.0);
        // SAFETY: `ct_line` is valid and metric pointers are valid stack locals.
        let width = unsafe { ct_line.typographic_bounds(&mut asc, &mut desc, &mut lead) } as f32;
        let (asc_f, desc_f) = (asc as f32, desc as f32);
        let max_span_pt = spans.iter().map(|s| s.size).fold(12.0f32, f32::max);
        let height = (asc_f + desc_f + (lead.max(0.0) as f32)).max(max_span_pt * opts.line_height_factor);
        let baseline_y = y_top + asc_f + (height - (asc_f + desc_f)) * 0.5;
        let abs_b_start = seg_byte_start + map.utf16_to_utf8(u16_range.start);
        let abs_b_end = seg_byte_start + map.utf16_to_utf8(u16_range.end);

        let mut caret_stops = Vec::new();
        for &(b_off, u16_off) in &map.boundaries {
            if u16_off >= u16_range.start && u16_off <= u16_range.end {
                // SAFETY: `u16_off` is a valid UTF-16 index for `ct_line`.
                let x =
                    unsafe { ct_line.offset_for_string_index(u16_off as isize, std::ptr::null_mut()) } as f32;
                let clamped_x = caret_stops
                    .last()
                    .map_or(x, |&(_, prev): &(usize, f32)| x.max(prev));
                caret_stops.push((seg_byte_start + b_off, clamped_x));
            }
        }

        let mut glyphs = Vec::new();
        // SAFETY: `ct_line` is valid.
        let runs: CFRetained<CFArray> = unsafe { ct_line.glyph_runs() };
        for r_idx in 0..runs.count() {
            // SAFETY: `r_idx` is in bounds and elements are `CTRun`.
            let run_ptr = unsafe { runs.value_at_index(r_idx) }.cast::<CTRun>();
            if run_ptr.is_null() {
                continue;
            }
            let run = unsafe { &*run_ptr };
            let g_count = unsafe { run.glyph_count() };
            if g_count <= 0 {
                continue;
            }
            let n = g_count as usize;
            let dict: CFRetained<CFDictionary> = unsafe { run.attributes() };
            let font_val = unsafe { dict.value((kCTFontAttributeName as *const CFString).cast()) };
            if font_val.is_null() {
                continue;
            }
            let run_font = unsafe { &*(font_val.cast::<CTFont>()) };
            let is_color =
                unsafe { run_font.symbolic_traits() }.contains(CTFontSymbolicTraits::TraitColorGlyphs);
            let size_tenths = (ct_font_point_size(run_font).max(6.0) * 10.0).round() as u16;
            let font_id = self.intern_ct_font(run_font, size_tenths);

            let mut run_glyphs = vec![0 as CGGlyph; n];
            let mut run_positions = vec![CGPoint { x: 0.0, y: 0.0 }; n];
            let mut run_indices = vec![0isize; n];
            let full_r = CFRange {
                location: 0,
                length: g_count,
            };
            // SAFETY: buffers have length `n == g_count`.
            unsafe {
                run.glyphs(full_r, NonNull::new_unchecked(run_glyphs.as_mut_ptr()));
                run.positions(full_r, NonNull::new_unchecked(run_positions.as_mut_ptr()));
                run.string_indices(full_r, NonNull::new_unchecked(run_indices.as_mut_ptr()));
            }
            for i in 0..n {
                let u16_i = (run_indices[i].max(0) as usize).min(map.utf16_len);
                let abs_byte = seg_byte_start + map.utf16_to_utf8(u16_i);
                let span_idx = span_slices
                    .iter()
                    .find(|(r, _, _)| abs_byte >= r.start && abs_byte < r.end)
                    .or_else(|| span_slices.last())
                    .map_or(0, |s| s.1);
                glyphs.push(PositionedGlyph {
                    key: GlyphRasterKey {
                        font_id,
                        glyph_id: run_glyphs[i],
                        size_tenths_pt: size_tenths,
                        scale_tenths,
                        subpx_x: 0,
                        is_color,
                    },
                    pen_x: run_positions[i].x as f32,
                    baseline_y: baseline_y - (run_positions[i].y as f32),
                    color: spans[span_idx].color,
                });
            }
        }

        let mut shaped = ShapedLine {
            byte_range: abs_b_start..abs_b_end,
            y_top,
            baseline_y,
            ascent: asc_f,
            descent: desc_f,
            height,
            width: width.max(0.0),
            x_offset: 0.0,
            glyphs,
            decorations: Vec::new(),
            caret_stops,
        };
        for (range, idx, _) in span_slices {
            let span = &spans[*idx];
            let (s, e) = (range.start.max(abs_b_start), range.end.min(abs_b_end));
            if s >= e || (span.background.is_none() && !span.underline && !span.strikethrough) {
                continue;
            }
            let (x0, x1) = (shaped.x_for_byte_index(s), shaped.x_for_byte_index(e));
            if x1 <= x0 {
                continue;
            }
            if let Some(bg) = span.background {
                shaped.decorations.push(LineDecoration {
                    rect: Rect::new(x0 - 1.0, y_top + 1.0, (x1 - x0) + 2.0, height - 2.0),
                    color: bg,
                    is_background: true,
                });
            }
            if span.underline {
                shaped.decorations.push(LineDecoration {
                    rect: Rect::new(x0, baseline_y + 1.5, x1 - x0, 1.0),
                    color: span.color,
                    is_background: false,
                });
            }
            if span.strikethrough {
                shaped.decorations.push(LineDecoration {
                    rect: Rect::new(x0, baseline_y - asc_f * 0.32, x1 - x0, 1.0),
                    color: span.color,
                    is_background: false,
                });
            }
        }
        shaped
    }
}
