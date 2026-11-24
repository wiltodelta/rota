//! Rich text spans, shaped paragraph geometry, hit-testing, and glyph/paragraph caching.

use std::collections::HashMap;
use std::hash::{Hash, Hasher};
use std::ops::Range;

use crate::atlas::{AtlasRegion, TextureAtlas};
use crate::color::Color;
use crate::geometry::{Point, Rect, Size};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum FontFamily {
    UiSans,
    Mono,
    System,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum FontWeight {
    Regular,
    Medium,
    Semibold,
    Bold,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum FontStyle {
    Normal,
    Italic,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
pub enum TextAlign {
    #[default]
    Left,
    Center,
    Right,
}

#[derive(Debug, Clone, PartialEq)]
pub struct TextSpan {
    pub text: String,
    pub font: FontFamily,
    pub size: f32,
    pub weight: FontWeight,
    pub style: FontStyle,
    pub color: Color,
    pub background: Option<Color>,
    pub underline: bool,
    pub strikethrough: bool,
}

impl TextSpan {
    pub fn new(text: impl Into<String>, size: f32, color: Color) -> Self {
        Self {
            text: text.into(),
            font: FontFamily::UiSans,
            size,
            weight: FontWeight::Regular,
            style: FontStyle::Normal,
            color,
            background: None,
            underline: false,
            strikethrough: false,
        }
    }

    #[inline]
    pub fn mono(mut self) -> Self {
        self.font = FontFamily::Mono;
        self
    }

    #[inline]
    pub fn font(mut self, font: FontFamily) -> Self {
        self.font = font;
        self
    }

    #[inline]
    pub fn weight(mut self, weight: FontWeight) -> Self {
        self.weight = weight;
        self
    }

    #[inline]
    pub fn italic(mut self) -> Self {
        self.style = FontStyle::Italic;
        self
    }

    #[inline]
    pub fn underline(mut self) -> Self {
        self.underline = true;
        self
    }

    #[inline]
    pub fn strikethrough(mut self) -> Self {
        self.strikethrough = true;
        self
    }

    #[inline]
    pub fn background(mut self, bg: Color) -> Self {
        self.background = Some(bg);
        self
    }
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct TextLayoutOpts {
    pub max_width: Option<f32>,
    pub max_lines: Option<usize>,
    pub line_height_factor: f32,
    pub align: TextAlign,
}

impl Default for TextLayoutOpts {
    fn default() -> Self {
        Self {
            max_width: None,
            max_lines: None,
            line_height_factor: 1.32,
            align: TextAlign::Left,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct GlyphRasterKey {
    pub font_id: u32,
    pub glyph_id: u16,
    pub size_tenths_pt: u16,
    pub scale_tenths: u16,
    pub subpx_x: u8,
    pub is_color: bool,
}

#[derive(Debug, Clone, Copy)]
pub struct AtlasGlyphEntry {
    pub region: AtlasRegion,
    pub offset_from_pen: Point,
    pub pixel_offset: Point,
    pub logical_size: Size,
    pub is_color: bool,
}

#[derive(Debug, Clone, Copy)]
pub struct PositionedGlyph {
    pub key: GlyphRasterKey,
    pub pen_x: f32,
    pub baseline_y: f32,
    pub color: Color,
}

#[derive(Debug, Clone, Copy)]
pub struct LineDecoration {
    pub rect: Rect,
    pub color: Color,
    pub is_background: bool,
}

#[derive(Debug, Clone)]
pub struct ShapedLine {
    pub byte_range: Range<usize>,
    pub y_top: f32,
    pub baseline_y: f32,
    pub ascent: f32,
    pub descent: f32,
    pub height: f32,
    pub width: f32,
    pub x_offset: f32,
    pub glyphs: Vec<PositionedGlyph>,
    pub decorations: Vec<LineDecoration>,
    /// Monotonic `(utf8_byte_index, local_x_from_line_origin)` pairs at valid char boundaries.
    pub caret_stops: Vec<(usize, f32)>,
}

impl ShapedLine {
    /// Returns the horizontal caret coordinate (including `x_offset`) for `byte_idx`.
    pub fn x_for_byte_index(&self, byte_idx: usize) -> f32 {
        if self.caret_stops.is_empty() {
            return self.x_offset;
        }
        if byte_idx <= self.caret_stops[0].0 {
            return self.x_offset + self.caret_stops[0].1;
        }
        if let Some(&(last_b, last_x)) = self.caret_stops.last()
            && byte_idx >= last_b
        {
            return self.x_offset + last_x;
        }
        match self.caret_stops.binary_search_by_key(&byte_idx, |&(b, _)| b) {
            Ok(i) => self.x_offset + self.caret_stops[i].1,
            Err(i) => {
                let prev = self.caret_stops[i.saturating_sub(1)];
                self.x_offset + prev.1
            }
        }
    }

    /// Finds the nearest valid UTF-8 character boundary to `local_x` (relative to paragraph origin).
    pub fn byte_index_at_x(&self, local_x: f32) -> usize {
        let rel_x = local_x - self.x_offset;
        if self.caret_stops.is_empty() {
            return self.byte_range.start;
        }
        if rel_x <= self.caret_stops[0].1 {
            return self.caret_stops[0].0;
        }
        for pair in self.caret_stops.windows(2) {
            let (b0, x0) = pair[0];
            let (b1, x1) = pair[1];
            let mid = (x0 + x1) * 0.5;
            if rel_x < mid {
                return b0;
            }
            if rel_x <= x1 {
                return b1;
            }
        }
        self.caret_stops.last().map_or(self.byte_range.end, |&(b, _)| b)
    }
}

#[derive(Debug, Clone)]
pub struct ShapedParagraph {
    pub size: Size,
    pub lines: Vec<ShapedLine>,
    pub truncated: bool,
    pub total_bytes: usize,
    pub scale_factor: f32,
}

impl ShapedParagraph {
    pub fn line_index_at_y(&self, local_y: f32) -> usize {
        if self.lines.is_empty() || local_y <= 0.0 {
            return 0;
        }
        for (i, line) in self.lines.iter().enumerate() {
            if local_y < line.y_top + line.height {
                return i;
            }
        }
        self.lines.len() - 1
    }

    pub fn line_index_for_byte(&self, byte_idx: usize) -> usize {
        if self.lines.is_empty() {
            return 0;
        }
        for (i, line) in self.lines.iter().enumerate() {
            let is_last = i + 1 == self.lines.len();
            if byte_idx >= line.byte_range.start
                && (byte_idx < line.byte_range.end || (is_last && byte_idx <= self.total_bytes))
            {
                return i;
            }
            if byte_idx == line.byte_range.end
                && self
                    .lines
                    .get(i + 1)
                    .is_none_or(|n| n.byte_range.start > byte_idx)
            {
                return i;
            }
        }
        self.lines.len() - 1
    }

    pub fn byte_index_at_point(&self, local_point: Point) -> usize {
        if self.lines.is_empty() {
            return 0;
        }
        let line_idx = self.line_index_at_y(local_point.y);
        self.lines[line_idx].byte_index_at_x(local_point.x)
    }

    pub fn cursor_rect(&self, byte_idx: usize) -> Rect {
        if self.lines.is_empty() {
            return Rect::new(0.0, 0.0, 1.5, 16.0);
        }
        let idx = self.line_index_for_byte(byte_idx);
        let line = &self.lines[idx];
        let x = line.x_for_byte_index(byte_idx);
        Rect::new(x, line.y_top, 1.5, line.height.max(12.0))
    }

    pub fn selection_rects(&self, range: Range<usize>) -> Vec<Rect> {
        if range.start >= range.end || self.lines.is_empty() {
            return Vec::new();
        }
        let mut out = Vec::new();
        for line in &self.lines {
            let seg_start = range.start.max(line.byte_range.start);
            let seg_end = range.end.min(line.byte_range.end);
            if seg_start < seg_end {
                let x0 = line.x_for_byte_index(seg_start);
                let x1 = line.x_for_byte_index(seg_end).max(x0 + 3.0);
                out.push(Rect::new(x0, line.y_top, x1 - x0, line.height));
            } else if range.start <= line.byte_range.start
                && range.end > line.byte_range.end
                && line.byte_range.is_empty()
            {
                // Highlight empty newline inside selection.
                out.push(Rect::new(line.x_offset, line.y_top, 5.0, line.height));
            }
        }
        out
    }
}

/// Text shaping, measurement cache, and per-glyph GPU atlas rasterizer.
pub struct TextSystem {
    paragraph_cache: HashMap<u64, ShapedParagraph>,
    glyph_cache: HashMap<GlyphRasterKey, AtlasGlyphEntry>,
    #[cfg(target_os = "macos")]
    backend: crate::text_macos::MacFontBackend,
}

impl Default for TextSystem {
    fn default() -> Self {
        Self::new()
    }
}

impl TextSystem {
    const MAX_PARAGRAPH_CACHE: usize = 2048;

    pub fn new() -> Self {
        rota_platform::register_bundled_fonts();
        Self {
            paragraph_cache: HashMap::with_capacity(256),
            glyph_cache: HashMap::with_capacity(1024),
            #[cfg(target_os = "macos")]
            backend: crate::text_macos::MacFontBackend::new(),
        }
    }

    pub fn shape_paragraph(
        &mut self,
        spans: &[TextSpan],
        opts: TextLayoutOpts,
        scale_factor: f32,
    ) -> ShapedParagraph {
        let key = hash_paragraph_request(spans, opts, scale_factor);
        if let Some(cached) = self.paragraph_cache.get(&key) {
            return cached.clone();
        }
        if self.paragraph_cache.len() >= Self::MAX_PARAGRAPH_CACHE {
            self.paragraph_cache.clear();
        }
        let shaped = self.shape_uncached(spans, opts, scale_factor);
        self.paragraph_cache.insert(key, shaped.clone());
        shaped
    }

    pub fn resolve_glyph(
        &mut self,
        key: GlyphRasterKey,
        mask_atlas: &mut TextureAtlas,
        color_atlas: &mut TextureAtlas,
    ) -> Option<AtlasGlyphEntry> {
        let target_gen = if key.is_color {
            color_atlas.generation()
        } else {
            mask_atlas.generation()
        };
        if let Some(&entry) = self.glyph_cache.get(&key)
            && entry.region.generation == target_gen
        {
            return Some(entry);
        }

        #[cfg(target_os = "macos")]
        {
            let bmp = self.backend.rasterize_glyph(key)?;
            let atlas = if key.is_color { color_atlas } else { mask_atlas };
            let region = atlas.allocate_and_upload(bmp.pixel_w, bmp.pixel_h, bmp.rgba)?;
            let entry = AtlasGlyphEntry {
                region,
                offset_from_pen: bmp.offset_from_pen,
                pixel_offset: bmp.pixel_offset,
                logical_size: bmp.logical_size,
                is_color: key.is_color,
            };
            self.glyph_cache.insert(key, entry);
            Some(entry)
        }
        #[cfg(not(target_os = "macos"))]
        {
            let _ = (key, mask_atlas, color_atlas);
            None
        }
    }

    #[cfg(target_os = "macos")]
    pub fn resolved_postscript_name(
        &mut self,
        family: FontFamily,
        weight: FontWeight,
        style: FontStyle,
        size: f32,
    ) -> String {
        self.backend.resolved_postscript_name(family, weight, style, size)
    }

    fn shape_uncached(
        &mut self,
        spans: &[TextSpan],
        opts: TextLayoutOpts,
        scale_factor: f32,
    ) -> ShapedParagraph {
        #[cfg(target_os = "macos")]
        {
            self.backend.shape_paragraph(spans, opts, scale_factor)
        }
        #[cfg(not(target_os = "macos"))]
        {
            fallback_shape_paragraph(spans, opts, scale_factor)
        }
    }
}

fn hash_paragraph_request(spans: &[TextSpan], opts: TextLayoutOpts, scale_factor: f32) -> u64 {
    let mut h = std::collections::hash_map::DefaultHasher::new();
    spans.len().hash(&mut h);
    for s in spans {
        s.text.hash(&mut h);
        s.font.hash(&mut h);
        ((s.size * 20.0).round() as i32).hash(&mut h);
        s.weight.hash(&mut h);
        s.style.hash(&mut h);
        s.color.to_rgba8().hash(&mut h);
        s.background.map(Color::to_rgba8).hash(&mut h);
        s.underline.hash(&mut h);
        s.strikethrough.hash(&mut h);
    }
    opts.max_width.map(|w| (w * 4.0).round() as i32).hash(&mut h);
    opts.max_lines.hash(&mut h);
    ((opts.line_height_factor * 100.0).round() as i32).hash(&mut h);
    opts.align.hash(&mut h);
    ((scale_factor * 10.0).round() as i32).hash(&mut h);
    h.finish()
}

#[cfg(not(target_os = "macos"))]
fn fallback_shape_paragraph(spans: &[TextSpan], opts: TextLayoutOpts, _scale_factor: f32) -> ShapedParagraph {
    let full: String = spans.iter().map(|s| s.text.as_str()).collect();
    let base_size = spans.first().map_or(13.0, |s| s.size);
    let char_w = base_size * 0.58;
    let line_h = (base_size * opts.line_height_factor).ceil();
    let mut lines = Vec::new();
    let mut y = 0.0f32;
    let mut max_w = 0.0f32;
    let mut byte_cursor = 0usize;
    for raw in full.split('\n') {
        let mut stops = Vec::new();
        let mut x = 0.0f32;
        for (idx, _) in raw.char_indices() {
            stops.push((byte_cursor + idx, x));
            x += char_w;
        }
        stops.push((byte_cursor + raw.len(), x));
        max_w = max_w.max(x);
        lines.push(ShapedLine {
            byte_range: byte_cursor..byte_cursor + raw.len(),
            y_top: y,
            baseline_y: y + base_size,
            ascent: base_size * 0.8,
            descent: base_size * 0.2,
            height: line_h,
            width: x,
            x_offset: 0.0,
            glyphs: Vec::new(),
            decorations: Vec::new(),
            caret_stops: stops,
        });
        y += line_h;
        byte_cursor += raw.len() + 1;
    }
    ShapedParagraph {
        size: Size::new(max_w, y),
        lines,
        truncated: false,
        total_bytes: full.len(),
        scale_factor: _scale_factor.max(1.0),
    }
}
