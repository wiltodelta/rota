//! End-to-end integration tests for CoreText shaping, Taffy layout/clipping, selection, and headless Metal GPU rendering.

use crate::{
    A11yRole, A11ySpec, Color, ComputedUiTree, Edges, FontFamily, FontStyle, FontWeight, GpuRenderer,
    IconKind, Point, QuadSpec, Rect, Scene, SelectableBlock, Size, TextLayoutOpts, TextSpan, TextSystem,
    Theme, TranscriptSelection, UiActionId, UiElement,
};

#[test]
fn coretext_bundled_fonts_wrapping_truncation_and_multilingual_hit_testing() {
    let mut ts = TextSystem::new();
    #[cfg(target_os = "macos")]
    {
        let sans_ps =
            ts.resolved_postscript_name(FontFamily::UiSans, FontWeight::Semibold, FontStyle::Normal, 14.0);
        let mono_ps =
            ts.resolved_postscript_name(FontFamily::Mono, FontWeight::Regular, FontStyle::Normal, 13.0);
        assert!(
            sans_ps.starts_with("IBMPlexSans"),
            "expected bundled IBM Plex Sans, got {sans_ps}"
        );
        assert!(
            mono_ps.starts_with("JetBrainsMono"),
            "expected bundled JetBrains Mono, got {mono_ps}"
        );
    }

    // Multi-script UTF-8 + emoji hit-testing (Latin + Cyrillic + CJK + Emoji).
    let sample = "Rota Привет 日本語 🚀 ok";
    let shaped = ts.shape_paragraph(
        &[TextSpan::new(sample, 14.0, Color::BLACK)],
        TextLayoutOpts::default(),
        2.0,
    );
    assert_eq!(shaped.lines.len(), 1);
    let line = &shaped.lines[0];
    for (byte_idx, _) in sample.char_indices() {
        let x = line.x_for_byte_index(byte_idx);
        let hit = line.byte_index_at_x(x + 1.0);
        assert!(
            sample.is_char_boundary(hit),
            "hit {hit} must be valid UTF-8 boundary"
        );
        assert_eq!(hit, byte_idx);
    }

    // Word wrapping and max_lines ellipsis truncation.
    let long_text =
        "Scheduled routines run cleanly across Claude Code, Codex, Grok Build, Antigravity, and Shell.";
    let wrapped = ts.shape_paragraph(
        &[TextSpan::new(long_text, 13.0, Color::BLACK)],
        TextLayoutOpts {
            max_width: Some(160.0),
            max_lines: Some(2),
            ..Default::default()
        },
        2.0,
    );
    assert_eq!(wrapped.lines.len(), 2);
    assert!(wrapped.truncated);
}

#[test]
fn taffy_layout_clip_hit_test_and_modal_z_layer() {
    let mut ts = TextSystem::new();
    let theme = Theme::light();

    // Scroll viewport (100x80) clipping a button placed scrolled below y=120, plus a z_layer=2 modal overlay.
    let clipped_btn = UiElement::row()
        .id("clipped-btn")
        .height(40.0)
        .width(80.0)
        .flex_shrink(0.0)
        .on_click(UiActionId(1));
    let visible_btn = UiElement::row()
        .id("visible-btn")
        .height(40.0)
        .width(80.0)
        .flex_shrink(0.0)
        .on_click(UiActionId(2))
        .a11y(A11ySpec::new(A11yRole::Button, "Visible Action"));

    let scroll_box = UiElement::column()
        .id("scroll")
        .width(120.0)
        .height(60.0)
        .gap(40.0)
        .clip()
        .child(visible_btn)
        .child(clipped_btn);

    let root = UiElement::column()
        .width(400.0)
        .height(300.0)
        .padding(Edges::all(16.0))
        .bg(theme.canvas)
        .child(scroll_box);

    let tree = ComputedUiTree::compute(&mut ts, root.clone(), Size::new(400.0, 300.0), 2.0);
    // Visible button at (16, 16, 80, 40) hits cleanly.
    let hit_vis = tree.hit_test(Point::new(30.0, 30.0)).expect("hit visible");
    assert_eq!(hit_vis.action, Some(UiActionId(2)));

    // Clipped button starts at y = 16 + 40 + 40 = 96, outside scroll clip (16..76) -> must NOT hit!
    let clipped_rect = tree.bounds_by_id("clipped-btn").expect("clipped bounds");
    assert!(clipped_rect.y >= 90.0);
    assert!(tree.hit_test(clipped_rect.center()).is_none());

    // Add modal scrim at z_layer = 3 blocking lower layers + modal button on top.
    let modal_root = root.child(
        UiElement::column()
            .id("scrim")
            .absolute(Rect::new(0.0, 0.0, 400.0, 300.0))
            .z_layer(3, true)
            .child(
                UiElement::row()
                    .id("modal-ok")
                    .absolute(Rect::new(20.0, 20.0, 60.0, 32.0))
                    .on_click(UiActionId(99)),
            ),
    );
    let modal_tree = ComputedUiTree::compute(&mut ts, modal_root, Size::new(400.0, 300.0), 2.0);
    let top_hit = modal_tree.hit_test(Point::new(30.0, 30.0)).expect("modal hit");
    assert_eq!(top_hit.action, Some(UiActionId(99)));
    // Clicking at (88, 30) is directly over `visible-btn` (x=16..96) yet outside `modal-ok` (x=20..80),
    // so `scrim` (z_layer=3, blocks_lower=true) intercepts and blocks `visible-btn`!
    let scrim_hit = modal_tree.hit_test(Point::new(88.0, 30.0)).expect("scrim hit");
    assert_eq!(scrim_hit.id.as_deref(), Some("scrim"));
    assert_eq!(scrim_hit.action, None);
}

#[test]
fn cross_block_transcript_selection_extracts_utf8_lines() {
    let mut ts = TextSystem::new();
    let t1 = "First assistant block";
    let t2 = "Second code output";
    let p1 = ts.shape_paragraph(
        &[TextSpan::new(t1, 13.0, Color::BLACK)],
        TextLayoutOpts::default(),
        2.0,
    );
    let p2 = ts.shape_paragraph(
        &[TextSpan::new(t2, 13.0, Color::BLACK).mono()],
        TextLayoutOpts::default(),
        2.0,
    );
    let blocks = vec![
        SelectableBlock {
            block_id: 1,
            bounds: Rect::new(20.0, 20.0, 300.0, 24.0),
            paragraph: p1,
            plain_text: t1.to_string(),
        },
        SelectableBlock {
            block_id: 2,
            bounds: Rect::new(20.0, 60.0, 300.0, 24.0),
            paragraph: p2,
            plain_text: t2.to_string(),
        },
    ];
    let mut sel = TranscriptSelection::new();
    sel.select_all(&blocks);
    assert_eq!(
        sel.selected_text(&blocks),
        "First assistant block\nSecond code output"
    );
    assert!(!sel.highlight_rects_for_block(0, &blocks[0]).is_empty());
    assert!(!sel.highlight_rects_for_block(1, &blocks[1]).is_empty());
}

#[test]
fn headless_metal_gpu_renders_cards_shadows_icons_and_bundled_fonts_at_2x() {
    let mut renderer = GpuRenderer::new_headless().expect("Metal headless GPU init");
    let theme = Theme::dark();
    let mut scene = Scene::new(theme.canvas);

    // Draw elevated rounded card with crisp border and drop shadow.
    let card_rect = Rect::new(24.0, 24.0, 272.0, 132.0);
    scene.push_quad(
        QuadSpec::solid(card_rect, theme.surface)
            .rounded(12.0)
            .border(1.5, theme.accent)
            .shadow(10.0, Point::new(0.0, 4.0), theme.shadow_color),
    );

    // Draw vector icon inside card.
    renderer.draw_icon(
        &mut scene,
        IconKind::Sparkles,
        Rect::new(40.0, 40.0, 24.0, 24.0),
        theme.accent,
        2.0,
    );

    // Draw IBM Plex Sans heading + JetBrains Mono code span + Emoji!
    renderer.draw_text(
        &mut scene,
        Point::new(72.0, 38.0),
        &[
            TextSpan::new("Rota 120 Hz ", 16.0, theme.text_primary).weight(FontWeight::Bold),
            TextSpan::new("wgpu::Metal 🚀", 14.0, theme.success).mono(),
        ],
        TextLayoutOpts {
            max_width: Some(210.0),
            ..Default::default()
        },
        2.0,
    );

    let (px_w, px_h, rgba) = renderer
        .render_to_rgba(320, 180, 2.0, &scene)
        .expect("offscreen GPU render");
    assert_eq!((px_w, px_h), (640, 360));
    assert_eq!(rgba.len(), 640 * 360 * 4);

    let px_at = |x: u32, y: u32| -> [u8; 4] {
        let i = ((y * px_w + x) * 4) as usize;
        [rgba[i], rgba[i + 1], rgba[i + 2], rgba[i + 3]]
    };

    // Far top-left corner (4, 4) matches dark canvas.
    let exp_canvas = theme.canvas.to_rgba8();
    let bg_px = px_at(4, 4);
    assert!((i32::from(bg_px[0]) - i32::from(exp_canvas[0])).abs() <= 2);
    assert!((i32::from(bg_px[1]) - i32::from(exp_canvas[1])).abs() <= 2);

    // Inside card body below text (200, 260) matches dark surface.
    let exp_surf = theme.surface.to_rgba8();
    let surf_px = px_at(200, 260);
    assert!((i32::from(surf_px[0]) - i32::from(exp_surf[0])).abs() <= 2);
    assert!((i32::from(surf_px[2]) - i32::from(exp_surf[2])).abs() <= 2);

    // Count bright foreground pixels inside icon region (80..128, 80..128) and text region (144..560, 76..136).
    let mut icon_lit = 0usize;
    for y in 80..128 {
        for x in 80..128 {
            let p = px_at(x, y);
            if p[2] > 90 {
                icon_lit += 1;
            }
        }
    }
    assert!(icon_lit > 60, "expected crisp icon pixels on GPU, got {icon_lit}");

    let mut text_lit = 0usize;
    for y in 76..136 {
        for x in 144..560 {
            let p = px_at(x, y);
            if p[0] > 80 || p[1] > 100 || p[2] > 100 {
                text_lit += 1;
            }
        }
    }
    assert!(
        text_lit > 250,
        "expected crisp CoreText glyph pixels on GPU, got {text_lit}"
    );
}
