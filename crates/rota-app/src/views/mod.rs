//! Unified full-size Main Window layout: floating Tahoe sidebar card, unified toolbar, calm empty states, and AX layout gate.

pub mod composer;
pub mod controls;
pub mod form_rows;
pub mod import_sheet;
pub mod markdown_links;
pub mod markdown_view;
pub mod menu_items;
pub mod menu_overlay;
pub mod panel_view;
pub mod placeholders;
pub mod post_layout;
pub mod question_card;
pub mod routine_detail;
pub mod routine_form;
pub mod routine_schedule_form;
pub mod schedule_rows;
pub mod schedule_view;
pub mod session;
pub mod session_banners;
pub mod settings_agents;
pub mod settings_view;
pub mod sidebar;
pub mod sidebar_filters;
pub mod transcript_bubbles;
pub mod transcript_tools;
pub mod transcript_view;
pub mod widgets;

pub use post_layout::audit_a11y_tree;
use rota_ui::{
    A11yNode, A11yRole, A11ySpec, Color, ComputedUiTree, CursorKind, Edges, FontWeight, IconKind, Point,
    Rect, Scene, Size, TextLayoutOpts, TextSpan, Theme, UiElement,
};

use crate::actions::{AppAction, SidebarSelection};
use crate::app_state::AppState;
use crate::views::placeholders::{build_delete_confirm_modal, build_empty_placeholder};
use crate::views::widgets::{circle_action_button, hairline_h, icon_button};

pub fn render_main_window(
    state: &mut AppState,
    viewport: Size,
    scale_factor: f32,
    now_seconds: f64,
    renderer: &mut rota_ui::GpuRenderer,
) -> (Scene, Vec<A11yNode>) {
    state.now_seconds = now_seconds;
    if state
        .copied_feedback
        .as_ref()
        .is_some_and(|(_, t)| now_seconds - *t >= 1.5)
    {
        state.copied_feedback = None;
    }
    state.tick_all_scroll_physics(now_seconds);
    let mut tree = build_and_compute_tree(state, viewport, scale_factor, now_seconds, renderer);
    if post_layout::sync_measured_scroll_heights(state, &tree) {
        tree = build_and_compute_tree(state, viewport, scale_factor, now_seconds, renderer);
        let _ = post_layout::sync_measured_scroll_heights(state, &tree);
    }

    let theme = state.theme();
    if let Some(SidebarSelection::Session(sid)) = state.selection {
        transcript_tools::populate_selectable_blocks(state, sid, &tree, &mut renderer.text, scale_factor);
    }
    let clear = if state.window_vibrant {
        Color::TRANSPARENT
    } else {
        theme.surface
    };
    let mut scene = Scene::new(clear);
    let mut a11y_nodes = tree.paint(renderer, &mut scene, scale_factor);
    if state.has_open_modal() {
        a11y_nodes.retain(|n| {
            matches!(
                n.id.as_str(),
                "deleteConfirmModal" | "routineForm" | "importSheet"
            ) || n.role == A11yRole::Menu
        });
    }
    post_layout::populate_focus_order(state, &a11y_nodes);
    post_layout::sync_focused_a11y_flag(&mut a11y_nodes, &state.focus);
    if let Some(SidebarSelection::Session(sid)) = state.selection {
        transcript_tools::paint_selection_highlights(state, sid, &theme, &mut scene);
    }
    post_layout::paint_focus_ring(state, &tree, &theme, &mut scene);
    post_layout::paint_pressed_feedback(state, &tree, &theme, &mut scene);
    post_layout::paint_editor_caret(state, &tree, &theme, &mut scene, now_seconds);
    post_layout::paint_hover_tooltip(
        state,
        viewport,
        &theme,
        renderer,
        &mut scene,
        scale_factor,
        now_seconds,
    );
    transcript_tools::clamp_a11y_tree_to_parents(
        &mut a11y_nodes,
        Rect::from_origin_size(Point::ZERO, viewport),
    );
    state.last_tree = Some(tree);
    (scene, a11y_nodes)
}

fn build_and_compute_tree(
    state: &mut AppState,
    viewport: Size,
    scale_factor: f32,
    now_seconds: f64,
    renderer: &mut rota_ui::GpuRenderer,
) -> ComputedUiTree {
    state.viewport_size = viewport;
    state.actions.clear();
    state.activity_clock.reset_frame();
    let theme = state.theme();

    let sidebar_shown = state.sidebar_shown();
    let sb_frac = state.springs.animate(
        "sidebarOpen",
        if sidebar_shown { 1.0 } else { 0.0 },
        now_seconds,
        &mut state.activity_clock,
    );
    let sb_render = sb_frac > 0.01;
    let sb_margin = theme.ui_px(7.0);
    let split_w = if sidebar_shown && state.settings_pane.is_none() {
        6.0
    } else {
        0.0
    };
    let sb_card_w = state
        .settings
        .sidebar_width
        .min((viewport.width * 0.35).floor())
        .max(224.0);
    let sb_slot_w = if sb_render {
        ((sb_card_w + sb_margin + 3.0) * sb_frac).round()
    } else {
        0.0
    };
    let detail_w = (viewport.width - sb_slot_w - split_w).max(260.0);

    let toolbar_h = theme.ui_px(50.0).min(viewport.height * 0.2);
    let detail_body_h = (viewport.height - toolbar_h).max(100.0);

    let toolbar = build_detail_toolbar(state, &theme, detail_w, toolbar_h, sidebar_shown);
    let detail_body = build_detail_surface(state, &theme, detail_w, detail_body_h, now_seconds);

    let detail_col = UiElement::column()
        .width(detail_w)
        .height(viewport.height)
        .bg(theme.surface)
        .clip()
        .child(toolbar)
        .child(detail_body);

    let root_bg = if state.window_vibrant {
        theme.surface.with_alpha(0.84)
    } else {
        theme.surface
    };
    let mut root_row = UiElement::row()
        .width(viewport.width)
        .height(viewport.height)
        .bg(root_bg)
        .clip();

    if sb_render {
        let sb_card_h = (viewport.height - sb_margin * 2.0).max(120.0);
        let sb_inner = if let Some(pane) = state.settings_pane {
            settings_agents::build_settings_sidebar(state, &theme, pane, sb_card_w, sb_card_h)
        } else {
            sidebar::build_main_sidebar(state, &theme, sb_card_w, sb_card_h, now_seconds)
        };
        let card_fill = if state.window_vibrant {
            theme.sidebar.with_alpha(0.76)
        } else {
            theme.sidebar
        };
        let sb_gutter = UiElement::column()
            .width(sb_slot_w)
            .height(viewport.height)
            .padding(Edges::new(sb_margin, 3.0, sb_margin, sb_margin))
            .clip()
            .child(
                UiElement::column()
                    .width(sb_card_w)
                    .height(sb_card_h)
                    .rounded(theme.ui_px(13.0))
                    .bg(card_fill)
                    .border(1.0, theme.border)
                    .shadow(12.0, Point::new(0.0, 2.0), theme.shadow_color)
                    .clip()
                    .child(sb_inner),
            );
        root_row = root_row.child(sb_gutter);
        if split_w > 0.0 {
            root_row = root_row.child(
                UiElement::column()
                    .id("sidebarSplitter")
                    .width(split_w)
                    .height(viewport.height)
                    .cursor(CursorKind::ResizeColumn),
            );
        }
    }

    let mut root = UiElement::column()
        .width(viewport.width)
        .height(viewport.height)
        .clip()
        .child(root_row.child(detail_col));

    if let Some(overlay) = build_modal_overlay(state, &theme, viewport, now_seconds) {
        root = root.child(overlay);
    }
    if let Some(menu) = menu_overlay::build_open_menu(state, &theme, viewport) {
        root = root.child(menu);
    }

    ComputedUiTree::compute(&mut renderer.text, root, viewport, scale_factor)
}

fn build_detail_toolbar(
    state: &mut AppState,
    theme: &Theme,
    width: f32,
    height: f32,
    sidebar_shown: bool,
) -> UiElement {
    let title = state.window_title();
    let in_settings = state.settings_pane.is_some();
    let toggle_act = state
        .actions
        .register_named("toggleSidebar", AppAction::ToggleSidebar);
    let toggle_hovered = state.hovered_id.as_deref() == Some("toggleSidebar");

    let mut toggle_btn = circle_action_button(
        theme,
        "toggleSidebar",
        if sidebar_shown {
            "Hide Sidebar"
        } else {
            "Show Sidebar"
        },
        IconKind::Sidebar,
        toggle_act,
        false,
        false,
        !in_settings,
        toggle_hovered,
    );
    let t_sz = theme.ui_px(34.0);
    toggle_btn = toggle_btn.width(t_sz).height(t_sz).rounded(t_sz * 0.5).shadow(
        6.0,
        Point::new(0.0, 1.5),
        theme.shadow_color,
    );

    let lead_pad = if sidebar_shown {
        theme.ui_px(10.0)
    } else {
        theme.ui_px(80.0)
    };
    let actions_reserve = if in_settings { 24.0 } else { theme.ui_px(132.0) };
    let max_title_w = (width - lead_pad - theme.ui_px(58.0) - actions_reserve).max(80.0);

    let mut tspec = A11ySpec::new(A11yRole::Heading, &title);
    tspec.value = Some(title.clone());
    let title_el = UiElement::text(
        vec![TextSpan::new(&title, theme.ui_px(15.5), theme.text_primary).weight(FontWeight::Semibold)],
        TextLayoutOpts {
            max_width: Some(max_title_w),
            max_lines: Some(1),
            ..Default::default()
        },
    )
    .id("mainWindowTitle")
    .a11y(tspec);

    let left_group = UiElement::row()
        .align_center()
        .gap(theme.ui_px(10.0))
        .clip()
        .child(toggle_btn)
        .child(title_el);

    let mut bar = UiElement::row()
        .id("mainToolbar")
        .width(width)
        .height(height)
        .align_center()
        .justify_between()
        .padding(Edges::new(0.0, theme.ui_px(16.0), 0.0, lead_pad))
        .bg(theme.surface)
        .clip()
        .a11y(A11ySpec::new(A11yRole::Toolbar, "Toolbar"))
        .child(left_group);

    if !in_settings {
        let sched_shown = state.selection == Some(SidebarSelection::Schedule);
        let sched_avail = !state.routines.is_empty();
        let sched_act = state
            .actions
            .register_named("scheduleButton", AppAction::ToggleSchedule);
        let imp_act = state.actions.register_named("import", AppAction::OpenImportSheet);
        let new_act = state
            .actions
            .register_named("newRoutine", AppAction::OpenNewRoutine);
        let hov = state.hovered_id.clone();

        let actions_group = UiElement::row()
            .id("toolbarActions")
            .height(theme.ui_px(34.0))
            .align_center()
            .gap(theme.ui_px(2.0))
            .padding(Edges::xy(theme.ui_px(4.0), theme.ui_px(3.0)))
            .rounded(theme.ui_px(17.0))
            .bg(theme.elevated)
            .border(1.0, theme.border)
            .shadow(6.0, Point::new(0.0, 1.5), theme.shadow_color)
            .flex_shrink(0.0)
            .a11y(A11ySpec::new(A11yRole::Group, "Actions"))
            .child(icon_button(
                theme,
                "scheduleButton",
                if sched_shown {
                    "Hide Schedule"
                } else {
                    "Show Schedule"
                },
                IconKind::Calendar,
                sched_act,
                sched_shown,
                sched_avail,
                hov.as_deref() == Some("scheduleButton"),
            ))
            .child(icon_button(
                theme,
                "import",
                "Import Routines…",
                IconKind::Import,
                imp_act,
                false,
                true,
                hov.as_deref() == Some("import"),
            ))
            .child(icon_button(
                theme,
                "newRoutine",
                "New Routine…",
                IconKind::Plus,
                new_act,
                false,
                true,
                hov.as_deref() == Some("newRoutine"),
            ));
        bar = bar.child(actions_group);
    }
    bar
}

fn build_detail_surface(
    state: &mut AppState,
    theme: &Theme,
    width: f32,
    height: f32,
    now_seconds: f64,
) -> UiElement {
    if let Some(pane) = state.settings_pane {
        return UiElement::column()
            .width(width)
            .height(height)
            .bg(theme.surface)
            .clip()
            .child(hairline_h(theme))
            .child(settings_view::build_settings_detail(
                state,
                theme,
                pane,
                width,
                (height - 1.0).max(80.0),
                now_seconds,
            ));
    }
    let (body_h, err_opt) = if let Some(err) = state.error_banner.clone() {
        let bh = theme.ui_px(44.0);
        (
            (height - bh).max(80.0),
            Some(session_banners::build_error_banner(state, theme, &err, width)),
        )
    } else {
        (height, None)
    };
    let inner = match state.selection.clone() {
        Some(SidebarSelection::Schedule) if !state.routines.is_empty() => {
            schedule_view::build_schedule_view(state, theme, width, body_h, now_seconds)
        }
        Some(SidebarSelection::Session(sid)) => {
            if let Some(rec) = state
                .scheduler
                .current_record(sid)
                .or_else(|| state.sessions.iter().find(|s| s.id == sid).cloned())
                && let Some(routine) = state.routines.iter().find(|r| r.id == rec.routine_id).cloned()
            {
                session::build_session_view(state, theme, &rec, &routine, width, body_h, now_seconds)
            } else {
                build_empty_placeholder(state, theme, width, body_h)
            }
        }
        Some(SidebarSelection::Routine(rid)) => {
            if let Some(routine) = state.routines.iter().find(|r| r.id == rid).cloned() {
                routine_detail::build_routine_detail(state, theme, &routine, width, body_h, now_seconds)
            } else {
                build_empty_placeholder(state, theme, width, body_h)
            }
        }
        _ => build_empty_placeholder(state, theme, width, body_h),
    };
    if let Some(banner) = err_opt {
        UiElement::column()
            .width(width)
            .height(height)
            .bg(theme.surface)
            .clip()
            .child(banner)
            .child(inner)
    } else {
        inner
    }
}

fn build_modal_overlay(
    state: &mut AppState,
    theme: &Theme,
    viewport: Size,
    now_seconds: f64,
) -> Option<UiElement> {
    let dialog = if state.confirm_delete_session.is_some() || state.confirm_delete_routine.is_some() {
        Some(build_delete_confirm_modal(state, theme, viewport))
    } else if state.routine_modal.is_some() {
        Some(routine_form::build_routine_form_modal(
            state,
            theme,
            viewport,
            now_seconds,
        ))
    } else if state.import_modal.is_some() {
        Some(import_sheet::build_import_sheet_modal(
            state,
            theme,
            viewport,
            now_seconds,
        ))
    } else {
        let _ = state
            .springs
            .animate("modalOpen", 0.0, now_seconds, &mut state.activity_clock);
        None
    }?;

    let open_prog = state
        .springs
        .animate("modalOpen", 1.0, now_seconds, &mut state.activity_clock);
    let modal_h = resolve_length_dbg(&dialog.style.size.height).unwrap_or(460.0);
    let lift_y = (1.0 - open_prog) * theme.ui_px(8.0);
    let pad_top = ((viewport.height - modal_h) * 0.5 + lift_y).max(12.0);
    Some(
        UiElement::column()
            .id("modalScrim")
            .absolute(Rect::from_origin_size(Point::ZERO, viewport))
            .align_center()
            .padding(Edges::new(pad_top, 0.0, 0.0, 0.0))
            .bg(theme
                .modal_scrim
                .with_alpha(theme.modal_scrim.a * open_prog.clamp(0.35, 1.0)))
            .z_layer(10, true)
            .clip()
            .child(dialog),
    )
}

fn resolve_length_dbg<T: std::fmt::Debug>(dim: &T) -> Option<f32> {
    let s = format!("{dim:?}");
    s.strip_prefix("Length(")?.strip_suffix(')')?.parse::<f32>().ok()
}
