//! Native macOS SF Symbols & official `HarnessLogos.xcassets` vector rasterizer into `mask_atlas`.

#![cfg(target_os = "macos")]

use std::ffi::c_void;

use objc2::AnyThread;
use objc2::msg_send;
use objc2::rc::Retained;
use objc2_app_kit::{NSGraphicsContext, NSImage, NSImageSymbolConfiguration};
use objc2_core_graphics::{CGBitmapContextCreate, CGColorSpace, CGImageAlphaInfo};
use objc2_foundation::{NSData, NSPoint, NSRect, NSSize, NSString};

use crate::icons::IconKind;

const CLAUDE_SVG: &[u8] = include_bytes!("../../../HarnessLogos.xcassets/harness-claude.imageset/claude.svg");
const CODEX_SVG: &[u8] = include_bytes!("../../../HarnessLogos.xcassets/harness-codex.imageset/codex.svg");
const GROK_SVG: &[u8] = include_bytes!("../../../HarnessLogos.xcassets/harness-grok.imageset/grok.svg");
const ANTIGRAVITY_SVG: &[u8] =
    include_bytes!("../../../HarnessLogos.xcassets/harness-antigravity.imageset/antigravity.svg");

pub(crate) fn rasterize_macos_icon(kind: IconKind, px: u32) -> Option<Vec<u8>> {
    let px = px.max(8);
    let img = load_vector_image(kind, px as f64)?;
    let img_sz = img.size();
    if img_sz.width <= 0.1 || img_sz.height <= 0.1 {
        return None;
    }

    let mut rgba = vec![0u8; (px * px * 4) as usize];
    let space = CGColorSpace::new_device_rgb()?;
    // SAFETY: `rgba` outlives `cg_ctx` and matches `px * 4 * px`.
    let cg_ctx = unsafe {
        CGBitmapContextCreate(
            rgba.as_mut_ptr().cast::<c_void>(),
            px as usize,
            px as usize,
            8,
            (px * 4) as usize,
            Some(&space),
            CGImageAlphaInfo::PremultipliedLast.0,
        )
    }?;

    let ns_gfx = NSGraphicsContext::graphicsContextWithCGContext_flipped(&cg_ctx, false);
    NSGraphicsContext::saveGraphicsState_class();
    NSGraphicsContext::setCurrentContext(Some(&ns_gfx));

    let pad = (px as f64) * 0.04;
    let avail = ((px as f64) - pad * 2.0).max(2.0);
    let scale = (avail / img_sz.width).min(avail / img_sz.height);
    let draw_w = (img_sz.width * scale).round().max(1.0);
    let draw_h = (img_sz.height * scale).round().max(1.0);
    let dst = NSRect::new(
        NSPoint::new(
            (((px as f64) - draw_w) * 0.5).floor(),
            (((px as f64) - draw_h) * 0.5).floor(),
        ),
        NSSize::new(draw_w, draw_h),
    );
    img.drawInRect(dst);

    NSGraphicsContext::restoreGraphicsState_class();

    // Normalize every drawn pixel to pure white + antialiased alpha mask `[255, 255, 255, a]`.
    let mut any_lit = false;
    for chunk in rgba.as_chunks_mut::<4>().0 {
        let a = chunk[3];
        if a > 0 {
            any_lit = true;
            *chunk = [255, 255, 255, a];
        } else {
            *chunk = [0, 0, 0, 0];
        }
    }
    any_lit.then_some(rgba)
}

fn load_vector_image(kind: IconKind, target_px: f64) -> Option<Retained<NSImage>> {
    let svg_bytes: Option<(&str, &[u8])> = match kind {
        IconKind::Claude => Some(("harness-claude", CLAUDE_SVG)),
        IconKind::Codex => Some(("harness-codex", CODEX_SVG)),
        IconKind::Grok => Some(("harness-grok", GROK_SVG)),
        IconKind::Antigravity => Some(("harness-antigravity", ANTIGRAVITY_SVG)),
        _ => None,
    };
    if let Some((asset_name, raw_svg)) = svg_bytes {
        if let Some(named) = NSImage::imageNamed(&NSString::from_str(asset_name)) {
            return Some(named);
        }
        let data = NSData::with_bytes(raw_svg);
        return NSImage::initWithData(NSImage::alloc(), &data);
    }

    let candidates: &[&str] = match kind {
        IconKind::Plus => &["plus"],
        IconKind::Play => &["play.fill"],
        IconKind::Stop => &["stop.fill"],
        IconKind::Pause => &["pause.fill"],
        IconKind::Check => &["checkmark"],
        IconKind::ChevronRight => &["chevron.right"],
        IconKind::ChevronDown => &["chevron.down"],
        IconKind::Sidebar => &["sidebar.left"],
        IconKind::Calendar => &["calendar"],
        IconKind::Import => &["square.and.arrow.down"],
        IconKind::Settings => &["gearshape"],
        IconKind::Sliders => &["slider.horizontal.3"],
        IconKind::Back => &["chevron.left", "arrow.left"],
        IconKind::Search => &["magnifyingglass"],
        IconKind::Terminal => &["apple.terminal", "terminal"],
        IconKind::Shell => &["terminal", "apple.terminal"],
        IconKind::Folder => &["folder"],
        IconKind::FileText => &["doc.text.magnifyingglass", "doc.text"],
        IconKind::Paperclip => &["paperclip"],
        IconKind::Send | IconKind::ArrowUp => &["arrow.up"],
        IconKind::Trash => &["trash"],
        IconKind::Sparkles => &["sparkles"],
        IconKind::ExternalLink => &["arrow.up.right.square"],
        IconKind::Copy => &["doc.on.doc"],
        IconKind::Warning => &["exclamationmark.triangle.fill"],
        IconKind::BubbleAlert => &["exclamationmark.bubble.fill"],
        IconKind::EnvelopeBadge => &["envelope.badge", "envelope"],
        IconKind::Info => &["info.circle"],
        IconKind::Question => &["questionmark.circle"],
        IconKind::Clock => &["clock"],
        IconKind::Filter => &["line.3.horizontal.decrease.circle", "line.3.horizontal.decrease"],
        IconKind::Close => &["xmark"],
        IconKind::Refresh => &["arrow.triangle.2.circlepath", "arrow.clockwise"],
        IconKind::ArrowDown => &["arrow.down"],
        IconKind::TextFormatSize => &["textformat.size"],
        IconKind::MinusCircle => &["minus.circle"],
        IconKind::TrayFull => &["tray.full"],
        IconKind::CheckCircle => &["checkmark.circle"],
        IconKind::StopCircle => &["stop.circle"],
        IconKind::PauseCircle => &["pause.circle"],
        IconKind::Repeat => &["repeat"],
        IconKind::Square => &["square"],
        IconKind::Bubbles => &["bubble.left.and.text.bubble.right"],
        IconKind::Wrench => &["wrench.and.screwdriver"],
        IconKind::Claude | IconKind::Codex | IconKind::Grok | IconKind::Antigravity => &[],
    };

    for &sym in candidates {
        let ns_sym = NSString::from_str(sym);
        if let Some(base) = NSImage::imageWithSystemSymbolName_accessibilityDescription(&ns_sym, None) {
            // Configure full optical weight & scale so SF Symbols match native Tahoe controls at 2x.
            let pt = (target_px * 0.78).max(11.0);
            let cfg: Option<Retained<NSImageSymbolConfiguration>> = unsafe {
                msg_send![
                    objc2::class!(NSImageSymbolConfiguration),
                    configurationWithPointSize: pt,
                    weight: 0.20f64
                ]
            };
            if let Some(cfg) = cfg
                && let Some(configured) = base.imageWithSymbolConfiguration(&cfg)
            {
                return Some(configured);
            }
            return Some(base);
        }
    }
    None
}
