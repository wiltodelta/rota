//! Post-layout pass: exact Taffy scroll-height feedback, zero-shift geometric text carets, and Tahoe tooltips.

use rota_ui::{
    A11yNode, A11yRole, ComputedUiTree, FontWeight, GpuRenderer, Point, QuadSpec, Rect, Scene, Size,
    TextLayoutOpts, TextSpan, Theme,
};

use crate::actions::{FocusTarget, SidebarSelection};
use crate::app_state::AppState;

/// Updates every `VirtualScrollState` with exact Taffy-measured content heights.
/// Returns `true` if `stick_to_bottom` changed `scroll_y` by > 1 pt so frame 1 lands pixel-exact.
pub fn sync_measured_scroll_heights(state: &mut AppState, tree: &ComputedUiTree) -> bool {
    let mut jumped = false;

    if let (Some(vp), Some(ct)) = (
        tree.bounds_by_id("routineSidebar"),
        tree.bounds_by_id("sidebarContent"),
    ) {
        state.sidebar_scroll.set_heights(&[ct.height], vp.height);
    }

    if let Some(pane) = state.settings_pane
        && let (Some(vp), Some(ct)) = (
            tree.bounds_by_id(&format!("settingsScroll-{}", pane.as_str())),
            tree.bounds_by_id("settingsContent"),
        )
    {
        state.settings_scroll.set_heights(&[ct.height], vp.height);
    }

    if let (Some(vp), Some(ct)) = (
        tree.bounds_by_id("routineHistoryScroll"),
        tree.bounds_by_id("routineDetailContent"),
    ) {
        state.routine_detail_scroll.set_heights(&[ct.height], vp.height);
    }

    if let (Some(vp), Some(ct)) = (
        tree.bounds_by_id("scheduleList"),
        tree.bounds_by_id("scheduleContent"),
    ) {
        state.schedule_state.scroll.set_heights(&[ct.height], vp.height);
        if let Some(day_id) = state.schedule_state.pending_scroll_day.take()
            && let Some(hdr) = tree.bounds_by_id(&format!("scheduleDayHeader-{day_id}"))
        {
            let max_s = (ct.height - vp.height).max(0.0);
            let rel_y = (hdr.y - ct.y - 4.0).clamp(0.0, max_s);
            state.schedule_state.scroll.scroll_y = rel_y;
            jumped = true;
        }
    }

    if let Some(form) = &mut state.routine_modal
        && let (Some(vp), Some(ct)) = (
            tree.bounds_by_id("routineFormScroll"),
            tree.bounds_by_id("routineFormContent"),
        )
    {
        form.scroll.set_heights(&[ct.height], vp.height);
    }

    if let Some(imp) = &mut state.import_modal
        && let (Some(vp), Some(ct)) = (
            tree.bounds_by_id("importResults"),
            tree.bounds_by_id("importSheetContent"),
        )
    {
        imp.scroll.set_heights(&[ct.height], vp.height);
    }

    if let Some(SidebarSelection::Session(sid)) = state.selection
        && let Some(vp) = tree.bounds_by_id("chatTranscript")
    {
        let prev_y = state.transcripts.get(&sid).map_or(0.0, |t| t.scroll.scroll_y);
        let prev_over = state
            .transcripts
            .get(&sid)
            .is_some_and(|t| t.scroll.total_height() > vp.height + 1.0);
        if let Some(tr) = state.transcripts.get_mut(&sid) {
            if let Some(ct) = tree.bounds_by_id("transcriptContentFull") {
                tr.scroll.set_heights(&[ct.height], vp.height);
            } else {
                let gap = 16.0;
                for idx in 0..tr.scroll.item_count() {
                    if let Some(rb) = tree.bounds_by_id(&format!("chatRow-{idx}")) {
                        tr.scroll.update_item_height(idx, rb.height + gap, vp.height);
                    }
                }
            }
        }
        state.ensure_focused_editor_visible(tree);
        if let Some(tr) = state.transcripts.get_mut(&sid) {
            let dy = tr.scroll.scroll_y - prev_y;
            let next_over = tr.scroll.total_height() > vp.height + 1.0;
            if dy.abs() > 1.0 || prev_over != next_over {
                jumped = true;
            }
            let bar_h = tree.bounds_by_id("showQuestion").map_or(0.0, |_| 44.0);
            let avail_h = vp.height + bar_h;
            let q_vis = tree.bounds_by_id("questionCard").is_some_and(|qb| {
                let min_y = qb.min_y() - dy;
                let max_y = qb.max_y() - dy;
                qb.height > 0.0
                    && qb.height <= avail_h - 8.0
                    && min_y >= vp.min_y() - 4.0
                    && max_y <= vp.min_y() + avail_h + 4.0
            });
            if tr.question_fully_visible != q_vis {
                tr.question_fully_visible = q_vis;
                jumped = true;
            }
        }
    } else {
        state.ensure_focused_editor_visible(tree);
    }
    jumped
}

pub fn populate_focus_order(state: &mut AppState, nodes: &[A11yNode]) {
    let mut out = Vec::new();
    fn map_id(id: &str) -> FocusTarget {
        match id {
            "routineSidebar" => FocusTarget::Sidebar,
            "composer" => FocusTarget::Composer,
            "chatTextScale" => FocusTarget::ChatTextScale,
            "routineSkill" => FocusTarget::RoutineSkill,
            "routineName" => FocusTarget::RoutineName,
            "routineFolder" => FocusTarget::RoutineFolder,
            "routineSchedule" => FocusTarget::RoutineSchedule,
            "routineRunLimit" => FocusTarget::RoutineRunLimit,
            "routinePrompt" => FocusTarget::RoutinePrompt,
            "importSearch" => FocusTarget::ImportSearch,
            s if s.starts_with("questionField-") => {
                FocusTarget::QuestionField(s["questionField-".len()..].to_string())
            }
            s if s.starts_with("quickReplyTitle-") => {
                s["quickReplyTitle-".len()..].parse::<usize>().map_or_else(
                    |_| FocusTarget::Control(id.to_string()),
                    FocusTarget::QuickReplyTitle,
                )
            }
            s if s.starts_with("quickReplyMsg-") => s["quickReplyMsg-".len()..].parse::<usize>().map_or_else(
                |_| FocusTarget::Control(id.to_string()),
                FocusTarget::QuickReplyMessage,
            ),
            _ => FocusTarget::Control(id.to_string()),
        }
    }
    fn walk(nodes: &[A11yNode], out: &mut Vec<FocusTarget>) {
        for n in nodes {
            if !n.enabled || n.bounds_in_window.width <= 0.0 || n.bounds_in_window.height <= 0.0 {
                continue;
            }
            if n.id == "routineSidebar" {
                let mut inner = Vec::new();
                walk(&n.children, &mut inner);
                let has_filter = inner
                    .iter()
                    .position(|t| t == &FocusTarget::Control("sessionFilter".to_string()));
                if let Some(pos) = has_filter {
                    let sf = inner.remove(pos);
                    out.extend(inner);
                    out.push(sf);
                } else {
                    out.extend(inner);
                }
                out.push(FocusTarget::Sidebar);
                continue;
            }
            let focusable = !n.id.is_empty()
                && !n.id.starts_with("copyAgent-")
                && !n.id.starts_with("copyUser-")
                && matches!(
                    n.role,
                    A11yRole::Button
                        | A11yRole::PopUpButton
                        | A11yRole::CheckBox
                        | A11yRole::RadioButton
                        | A11yRole::Slider
                        | A11yRole::TextField
                        | A11yRole::TextArea
                );
            if focusable {
                let tgt = map_id(&n.id);
                if !out.contains(&tgt) {
                    out.push(tgt);
                }
            }
            walk(&n.children, out);
        }
    }
    walk(nodes, &mut out);
    state.focus_order = out;
}

pub fn sync_focused_a11y_flag(nodes: &mut [A11yNode], focus: &Option<FocusTarget>) {
    let Some(f) = focus else {
        return;
    };
    let target_id: Option<&str> = match f {
        FocusTarget::Sidebar => Some("routineSidebar"),
        FocusTarget::Composer => Some("composer"),
        FocusTarget::ChatTextScale => Some("chatTextScale"),
        FocusTarget::Control(s) => Some(s.as_str()),
        _ => None,
    };
    let Some(tid) = target_id else {
        return;
    };
    fn walk_mut(nodes: &mut [A11yNode], tid: &str) {
        for n in nodes {
            if n.id == tid {
                n.focused = true;
            }
            walk_mut(&mut n.children, tid);
        }
    }
    walk_mut(nodes, tid);
}

pub fn paint_focus_ring(state: &AppState, tree: &ComputedUiTree, theme: &Theme, scene: &mut Scene) {
    let cid = match &state.focus {
        Some(FocusTarget::Control(id)) => id.as_str(),
        Some(FocusTarget::ChatTextScale) => "chatTextScale",
        _ => return,
    };
    let Some(bounds) = tree.bounds_by_id(cid) else {
        return;
    };
    if bounds.width <= 0.0 || bounds.height <= 0.0 {
        return;
    }
    let ring_rect = bounds.expand_uniform(1.5);
    let radius = (ring_rect.height * 0.5).min(theme.ui_px(16.0));
    scene.with_overlay(|s| {
        s.push_quad(
            QuadSpec::solid(ring_rect, rota_ui::Color::TRANSPARENT)
                .rounded(radius)
                .border(2.0, theme.selection_fill),
        );
    });
}

/// Paints a crisp 1.5 pt geometric cursor caret (with zero text layout shift, IME anchor, and 0%-idle-CPU blink).
pub fn paint_editor_caret(
    state: &mut AppState,
    tree: &ComputedUiTree,
    theme: &Theme,
    scene: &mut Scene,
    now_seconds: f64,
) {
    state.last_ime_cursor_rect = None;
    let Some(focus) = &state.focus else {
        return;
    };
    let (field_id, ed_opt): (String, Option<&rota_ui::TextEditState>) = match focus {
        FocusTarget::Composer => (
            "composer".to_string(),
            match state.selection {
                Some(SidebarSelection::Session(sid)) => state.composer_drafts.get(&sid),
                _ => None,
            },
        ),
        FocusTarget::RoutineSkill => (
            "routineSkill".to_string(),
            state.routine_modal.as_ref().map(|f| &f.skill_input),
        ),
        FocusTarget::RoutineName => (
            "routineName".to_string(),
            state.routine_modal.as_ref().map(|f| &f.name_input),
        ),
        FocusTarget::RoutineFolder => (
            "routineFolder".to_string(),
            state.routine_modal.as_ref().map(|f| &f.folder_input),
        ),
        FocusTarget::RoutineSchedule => (
            "routineSchedule".to_string(),
            state.routine_modal.as_ref().map(|f| &f.schedule_input),
        ),
        FocusTarget::RoutineRunLimit => (
            "routineRunLimit".to_string(),
            state.routine_modal.as_ref().map(|f| &f.run_limit_input),
        ),
        FocusTarget::RoutinePrompt => (
            "routinePrompt".to_string(),
            state.routine_modal.as_ref().map(|f| &f.prompt_input),
        ),
        FocusTarget::ImportSearch => (
            "importSearch".to_string(),
            state.import_modal.as_ref().map(|m| &m.search_input),
        ),
        FocusTarget::QuestionField(fid) => (
            format!("questionField-{fid}"),
            match state.selection {
                Some(SidebarSelection::Session(sid)) => state
                    .scheduler
                    .current_record(sid)
                    .and_then(|r| r.next_question().map(|q| q.id.clone()))
                    .and_then(|qid| {
                        state
                            .transcripts
                            .get(&sid)
                            .and_then(|tr| tr.question_editors.get(&(qid, fid.clone())))
                    }),
                _ => None,
            },
        ),
        FocusTarget::QuickReplyTitle(i) => (
            format!("quickReplyTitle-{i}"),
            state.quick_reply_edits.get(*i).map(|(_, t, _)| t),
        ),
        FocusTarget::QuickReplyMessage(i) => (
            format!("quickReplyMsg-{i}"),
            state.quick_reply_edits.get(*i).map(|(_, _, m)| m),
        ),
        _ => return,
    };

    let text_id = format!("{field_id}-text");
    let Some((bounds, shaped)) = tree.shaped_text_by_id(&text_id) else {
        return;
    };
    let clip_box = tree.bounds_by_id(&field_id).unwrap_or(bounds);

    let caret_rect = match ed_opt {
        Some(ed) if ed.has_selection() => return,
        Some(ed) if !ed.is_empty() => {
            let c = shaped.cursor_rect(ed.cursor());
            Rect::new(
                bounds.x + c.x,
                bounds.y + c.y + 1.0,
                1.5,
                (c.height - 2.0).max(theme.ui_px(14.0)),
            )
        }
        _ => Rect::new(bounds.x, bounds.y + 1.5, 1.5, theme.body_size() * 1.26),
    };

    state.last_ime_cursor_rect = Some(caret_rect);
    let elapsed = (now_seconds - state.last_caret_reset_time).max(0.0);
    let caret_visible = elapsed < 0.50 || ((elapsed / 0.53) as u64).is_multiple_of(2);

    if caret_visible && clip_box.expand_uniform(2.0).intersects(caret_rect) {
        scene.with_overlay(|s| {
            s.push_clip(clip_box.expand_uniform(2.0));
            s.push_quad(QuadSpec::solid(caret_rect, theme.selection_fill).rounded(0.75));
            s.pop_clip();
        });
    }
}

/// Paints tactile macOS button press feedback (`MouseDown` highlight) while pointer stays inside the pressed control.
pub fn paint_pressed_feedback(state: &AppState, tree: &ComputedUiTree, theme: &Theme, scene: &mut Scene) {
    let Some(ref pid) = state.pressed_id else {
        return;
    };
    if state.hovered_id.as_deref() != Some(pid.as_str()) {
        return;
    }
    let Some(bounds) = tree.bounds_by_id(pid) else {
        return;
    };
    let radius = (bounds.height * 0.5).min(theme.ui_px(14.0));
    let tint = match theme.appearance {
        rota_ui::Appearance::Light => rota_ui::Color::BLACK.with_alpha(0.075),
        rota_ui::Appearance::Dark => rota_ui::Color::WHITE.with_alpha(0.095),
    };
    scene.with_overlay(|s| {
        s.push_quad(QuadSpec::solid(bounds, tint).rounded(radius));
    });
}

/// Paints a native-styled macOS Tahoe tooltip pill when hovering an icon control for >= 0.35s.
pub fn paint_hover_tooltip(
    state: &mut AppState,
    viewport: Size,
    theme: &Theme,
    renderer: &mut GpuRenderer,
    scene: &mut Scene,
    scale_factor: f32,
    now_seconds: f64,
) {
    let Some((_, ref tip, target_rect, since)) = state.hover_tooltip else {
        return;
    };
    let elapsed = now_seconds - since;
    if elapsed < 0.35 {
        state.activity_clock.mark_active();
        return;
    }
    let span = TextSpan::new(tip.clone(), theme.ui_px(11.5), theme.text_primary).weight(FontWeight::Medium);
    let shaped = renderer.text.shape_paragraph(
        &[span],
        TextLayoutOpts {
            max_width: Some(260.0),
            max_lines: Some(1),
            ..Default::default()
        },
        scale_factor,
    );
    let (pad_x, pad_y) = (theme.ui_px(8.0), theme.ui_px(4.5));
    let box_w = shaped.size.width.ceil() + pad_x * 2.0;
    let box_h = shaped.size.height.ceil() + pad_y * 2.0;
    let x = (target_rect.center().x - box_w * 0.5).clamp(8.0, (viewport.width - box_w - 8.0).max(8.0));
    let below_y = target_rect.max_y() + 6.0;
    let y = if below_y + box_h <= viewport.height - 6.0 {
        below_y
    } else {
        (target_rect.y - box_h - 6.0).max(6.0)
    };
    let pill = Rect::new(x, y, box_w, box_h);
    scene.with_overlay(|s| {
        s.push_quad(
            QuadSpec::solid(pill, theme.elevated)
                .rounded(theme.ui_px(6.0))
                .border(1.0, theme.border)
                .shadow(8.0, Point::new(0.0, 3.0), theme.shadow_color),
        );
        renderer.draw_shaped_paragraph(s, Point::new(x + pad_x, y + pad_y), &shaped);
    });
}

/// Mirrors `scripts/ui-driver.swift gate` line-for-line to verify `0` AX/layout violations.
pub fn audit_a11y_tree(nodes: &[A11yNode], viewport: Size) -> Vec<String> {
    let win_bounds = Rect::from_origin_size(Point::ZERO, viewport);
    let mut violations = Vec::new();
    audit_walk(
        nodes,
        win_bounds,
        Rect::INFINITE_CLIP,
        win_bounds,
        &mut violations,
    );
    violations
}

fn audit_walk(nodes: &[A11yNode], parent: Rect, clip: Rect, win_bounds: Rect, violations: &mut Vec<String>) {
    for ch in nodes {
        let rect = ch.bounds_in_window;
        let visible = rect.width > 0.0 && rect.height > 0.0 && rect.intersects(clip);
        let scrolls = matches!(ch.role, A11yRole::ScrollArea | A11yRole::Table);
        let in_list = ch.role == A11yRole::Row;
        let structural = scrolls || in_list || ch.role == A11yRole::Group;
        let tol = if structural { 2.0 } else { 1.0 };

        if ch.role == A11yRole::Menu {
            continue;
        }

        let clipped = rect.intersect(clip);
        if visible && !win_bounds.expand_uniform(tol).contains_rect(clipped) {
            violations.push(format!("outside window {:?} {} {:?}", ch.role, ch.id, rect));
        } else if visible
            && !scrolls
            && !in_list
            && parent.width > 0.0
            && !parent.expand_uniform(tol).contains_rect(rect)
        {
            violations.push(format!(
                "outside parent {:?} {} {:?} in {:?}",
                ch.role, ch.id, rect, parent
            ));
        }
        let next_parent = if scrolls {
            Rect::INFINITE_CLIP
        } else if in_list {
            Rect::new(rect.x - 8.0, -1.0e6, rect.width + 16.0, 2.0e6)
        } else {
            rect
        };
        let next_clip = if ch.role == A11yRole::ScrollArea {
            clip.intersect(rect)
        } else {
            clip
        };
        audit_walk(&ch.children, next_parent, next_clip, win_bounds, violations);
    }
}
