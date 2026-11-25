//! Automated regression tests for the `ui-audit-macos` Phase 4 fixes (`UX-PLAT`, `UX-LOGIC`, `UX-A11Y`, `UX-PREC`).

use rota_core::model::SessionFilter;
use rota_ui::{A11yEvent, A11yRole, Appearance, EditKey, GpuRenderer, Modifiers, Size, UiInputEvent};
use uuid::Uuid;

use crate::actions::{ActionRegistry, AppAction, FocusTarget, PanelInput, SettingsPane, SidebarSelection};
use crate::form_state::{ImportSheetState, RoutineFormState};
use crate::menu_validation::MenuValidationState;
use crate::render_test_fixture::make_fixture;
use crate::views::{panel_view, render_main_window};

fn find_a11y<'a>(nodes: &'a [rota_ui::A11yNode], id: &str) -> Option<&'a rota_ui::A11yNode> {
    for n in nodes {
        if n.id == id {
            return Some(n);
        }
        if let Some(found) = find_a11y(&n.children, id) {
            return Some(found);
        }
    }
    None
}

fn collect_a11y<'a>(nodes: &'a [rota_ui::A11yNode], out: &mut Vec<&'a rota_ui::A11yNode>) {
    for n in nodes {
        out.push(n);
        collect_a11y(&n.children, out);
    }
}

#[test]
fn logic_filter_contradiction_error_banner_question_visibility_and_copy_feedback() {
    let mut gpu = GpuRenderer::new_headless().expect("headless Metal GpuRenderer");
    let mut fx = make_fixture(Appearance::Light);
    let vp = Size::new(1060.0, 700.0);

    // UX-LOGIC-01: Selecting a Completed session then activating `Running` filter hides the non-matching session.
    fx.state
        .execute_action(AppAction::SelectSession(fx.session_review_id));
    fx.state
        .execute_action(AppAction::ToggleSessionFilter(SessionFilter::Running));
    assert!(
        fx.state.visible_sessions().is_empty(),
        "Completed session must not leak through active Running filter"
    );
    let (_, filt_a11y) = render_main_window(&mut fx.state, vp, 2.0, 1.0, &mut gpu);
    assert!(find_a11y(&filt_a11y, "resetSessionFilter").is_some());
    assert!(find_a11y(&filt_a11y, "sessionFilterEmpty").is_some());
    assert!(
        find_a11y(&filt_a11y, &format!("sessionRow-{}", fx.session_review_id)).is_none(),
        "Non-matching selected session row must not render alongside 'No matching sessions'"
    );
    fx.state.execute_action(AppAction::ResetSessionFilters);

    // UX-LOGIC-02: Failed quick reply populates `error_banner`, renders `#appErrorBanner`, and dismisses cleanly.
    fx.state.settings.quick_replies[0].title = "Ping".to_string();
    fx.state.settings.quick_replies[0].message = "Status?".to_string();
    fx.state.execute_action(AppAction::SendQuickReply {
        session_id: Uuid::new_v4(),
        index: 0,
    });
    assert!(fx.state.error_banner.is_some());
    let (_, err_a11y) = render_main_window(&mut fx.state, vp, 2.0, 1.1, &mut gpu);
    assert!(find_a11y(&err_a11y, "appErrorBanner").is_some());
    let dismiss_act = find_a11y(&err_a11y, "dismissErrorBanner")
        .and_then(|n| n.action)
        .expect("dismissErrorBanner action");
    fx.state
        .process_frame_inputs_at(&[], &[A11yEvent::Press(dismiss_act)], 2.0, 1.2);
    assert!(fx.state.error_banner.is_none());

    // UX-LOGIC-03: `showQuestion` hides when `questionCard` fits 100% in `chatTranscript`, shows when clipped.
    fx.state
        .execute_action(AppAction::SelectSession(fx.session_question_id));
    let _ = render_main_window(&mut fx.state, vp, 2.0, 1.3, &mut gpu);
    let (_, q_tall_a11y) = render_main_window(&mut fx.state, vp, 2.0, 1.35, &mut gpu);
    assert!(find_a11y(&q_tall_a11y, "questionCard").is_some());
    assert!(
        find_a11y(&q_tall_a11y, "showQuestion").is_none(),
        "Duplicate showQuestion banner must hide when QuestionCard is 100% visible"
    );
    fx.state.execute_action(AppAction::SelectQuestionOther {
        field_id: "format".to_string(),
    });
    let (_, q_other_a11y) = render_main_window(&mut fx.state, vp, 2.0, 1.38, &mut gpu);
    assert!(
        find_a11y(&q_other_a11y, "showQuestion").is_none(),
        "Duplicate showQuestion banner must also hide when Something else… expands inside 1060x700"
    );

    let short_vp = Size::new(820.0, 360.0);
    let _ = render_main_window(&mut fx.state, short_vp, 2.0, 1.4, &mut gpu);
    let (_, q_short_a11y) = render_main_window(&mut fx.state, short_vp, 2.0, 1.45, &mut gpu);
    assert!(
        find_a11y(&q_short_a11y, "showQuestion").is_some(),
        "showQuestion banner must appear when QuestionCard overflows short viewport"
    );

    // UX-LOGIC-06: Copy feedback switches button label to "Copied" and expires after 1.5s.
    fx.state
        .execute_action(AppAction::SelectSession(fx.session_review_id));
    let (_, rev_a11y) = render_main_window(&mut fx.state, vp, 2.0, 2.0, &mut gpu);
    let mut flat = Vec::new();
    collect_a11y(&rev_a11y, &mut flat);
    let copy_node = flat
        .iter()
        .copied()
        .find(|n| n.id.starts_with("copyAgent-"))
        .expect("copyAgent button");
    let copy_id = copy_node.id.clone();
    fx.state
        .process_frame_inputs_at(&[], &[A11yEvent::Press(copy_node.action.unwrap())], 2.0, 2.1);
    let (_, copied_a11y) = render_main_window(&mut fx.state, vp, 2.0, 2.2, &mut gpu);
    assert_eq!(
        find_a11y(&copied_a11y, &copy_id).map(|n| n.title.as_str()),
        Some("Copied")
    );
    fx.state.process_frame_inputs_at(&[], &[], 2.0, 4.0);
    let (_, expired_a11y) = render_main_window(&mut fx.state, vp, 2.0, 4.0, &mut gpu);
    assert_eq!(
        find_a11y(&expired_a11y, &copy_id).map(|n| n.title.as_str()),
        Some("Copy Message")
    );
}

#[test]
fn a11y_modal_isolation_keyboard_tab_ring_target_sizes_and_menu_validation() {
    let mut gpu = GpuRenderer::new_headless().expect("headless Metal GpuRenderer");
    let mut fx = make_fixture(Appearance::Dark);
    let vp = Size::new(1060.0, 700.0);

    // UX-A11Y-01: Modal overlays hide background sidebar/toolbar/session AX nodes completely.
    fx.state.routine_modal = Some(RoutineFormState::new_default());
    let (_, rf_a11y) = render_main_window(&mut fx.state, vp, 2.0, 1.0, &mut gpu);
    assert!(find_a11y(&rf_a11y, "routineForm").is_some());
    assert!(find_a11y(&rf_a11y, "routineSidebar").is_none());
    assert!(find_a11y(&rf_a11y, "mainToolbar").is_none());
    let v_modal = MenuValidationState::from_state(&fx.state);
    assert!(v_modal.modal_open);
    fx.state.routine_modal = None;

    // UX-LOGIC-05: Empty ImportSheet disables `importAgent` and hides `importSelectAll-*`.
    let mut imp = ImportSheetState::new();
    imp.scans = Some(Vec::new());
    fx.state.import_modal = Some(imp);
    let (_, im_a11y) = render_main_window(&mut fx.state, vp, 2.0, 1.1, &mut gpu);
    assert!(find_a11y(&im_a11y, "importSheet").is_some());
    assert!(find_a11y(&im_a11y, "routineSidebar").is_none());
    let imp_btn = find_a11y(&im_a11y, "importAgent").expect("importAgent");
    assert!(!imp_btn.enabled);
    let mut im_flat = Vec::new();
    collect_a11y(&im_a11y, &mut im_flat);
    assert!(im_flat.iter().all(|n| !n.id.starts_with("importSelectAll-")));
    fx.state.import_modal = None;

    // UX-A11Y-04: `routineSidebar` -> `Shift+Tab` lands on `sessionFilter`, and `Space` activates focused control.
    fx.state
        .execute_action(AppAction::SelectSession(fx.session_review_id));
    let _ = render_main_window(&mut fx.state, vp, 2.0, 1.2, &mut gpu);
    fx.state.process_frame_inputs_at(
        &[],
        &[A11yEvent::SetFocused {
            id: "routineSidebar".to_string(),
            action: None,
            focused: true,
        }],
        2.0,
        1.25,
    );
    assert_eq!(fx.state.focus, Some(FocusTarget::Sidebar));
    fx.state.process_frame_inputs_at(
        &[UiInputEvent::Key {
            key: EditKey::Tab,
            modifiers: Modifiers {
                shift: true,
                ..Default::default()
            },
        }],
        &[],
        2.0,
        1.3,
    );
    assert_eq!(
        fx.state.focus,
        Some(FocusTarget::Control("sessionFilter".to_string()))
    );
    fx.state.process_frame_inputs_at(
        &[UiInputEvent::Key {
            key: EditKey::Text(" ".to_string()),
            modifiers: Modifiers::default(),
        }],
        &[],
        2.0,
        1.35,
    );
    assert!(
        fx.state
            .open_menu
            .as_ref()
            .is_some_and(|(m, _)| *m == crate::actions::MenuId::SessionFilter)
    );
    fx.state.open_menu = None;

    // UX-A11Y-05, UX-A11Y-06, UX-PREC-01, UX-LOGIC-04: Headings, >=24pt targets, 28pt toolbar/header buttons, static code font.
    let (_, sess_a11y) = render_main_window(&mut fx.state, vp, 2.0, 1.4, &mut gpu);
    let sched_btn = find_a11y(&sess_a11y, "scheduleButton").expect("scheduleButton");
    let show_rt_btn = find_a11y(&sess_a11y, "showSessionRoutine").expect("showSessionRoutine");
    assert!((sched_btn.bounds_in_window.height - 28.0).abs() <= 0.5);
    assert!((show_rt_btn.bounds_in_window.height - 28.0).abs() <= 0.5);

    let mut all_sess = Vec::new();
    collect_a11y(&sess_a11y, &mut all_sess);
    assert!(
        all_sess.iter().any(|n| n.role == A11yRole::Heading),
        "Markdown and view titles must emit A11yRole::Heading"
    );
    for node in &all_sess {
        if matches!(
            node.role,
            A11yRole::Button | A11yRole::PopUpButton | A11yRole::CheckBox | A11yRole::Slider
        ) && !node.id.starts_with("selBlock-")
        {
            assert!(
                node.bounds_in_window.height >= 23.5,
                "Interactive control `{}` height {} < 24pt",
                node.id,
                node.bounds_in_window.height
            );
        }
    }

    fx.state
        .execute_action(AppAction::OpenSettings(Some(SettingsPane::Chat)));
    let (_, chat_st_a11y) = render_main_window(&mut fx.state, vp, 2.0, 1.5, &mut gpu);
    let code_font = find_a11y(&chat_st_a11y, "chatCodeFont").expect("chatCodeFont static label");
    assert_eq!(
        code_font.role,
        A11yRole::StaticText,
        "1-option JetBrains Mono must not masquerade as a PopUpButton"
    );
    assert!(code_font.action.is_none());
    let v_settings = MenuValidationState::from_state(&fx.state);
    assert!(v_settings.in_settings);
    fx.state.execute_action(AppAction::CloseSettings);

    // UX-PLAT-03 & UX-HIER-04: Empty MenuBarPanel exposes `panelNewRoutine` CTA + `panelSettings` on left.
    fx.state.routines.clear();
    let theme = fx.state.theme();
    let mut reg = ActionRegistry::new();
    let mut panel_map: Vec<(String, PanelInput)> = Vec::new();
    let panel_root = panel_view::build_panel_tree(&fx.state, &theme, 200.0, &mut reg, &mut panel_map);
    let panel_tree =
        rota_ui::ComputedUiTree::compute(&mut gpu.text, panel_root, Size::new(340.0, 200.0), 2.0);
    assert!(panel_tree.bounds_by_id("panelNewRoutine").is_some());
    assert!(panel_tree.bounds_by_id("panelSettings").is_some());
    assert_eq!(
        fx.state.selection,
        Some(SidebarSelection::Session(fx.session_review_id))
    );
}

#[test]
fn modal_header_body_and_footer_share_continuous_unbroken_border() {
    let mut gpu = GpuRenderer::new_headless().expect("headless Metal GpuRenderer");
    for appearance in [Appearance::Light, Appearance::Dark] {
        let mut fx = make_fixture(appearance);
        fx.state.window_vibrant = false;
        let vp = Size::new(1000.0, 680.0);

        for kind in ["routineForm", "importSheet"] {
            if kind == "routineForm" {
                fx.state.routine_modal = Some(RoutineFormState::new_default());
                fx.state.import_modal = None;
            } else {
                let mut imp = ImportSheetState::new();
                imp.scans = Some(Vec::new());
                fx.state.import_modal = Some(imp);
                fx.state.routine_modal = None;
            }
            let _ = render_main_window(&mut fx.state, vp, 2.0, 2.0, &mut gpu);
            let (scene, _) = render_main_window(&mut fx.state, vp, 2.0, 2.5, &mut gpu);
            let modal_b = fx
                .state
                .last_tree
                .as_ref()
                .and_then(|t| t.bounds_by_id(kind))
                .expect("modal bounds");
            let (pw, _ph, rgba) = gpu
                .render_to_rgba(vp.width as u32, vp.height as u32, 2.0, &scene)
                .expect("render modal to rgba");

            let lx = (modal_b.x * 2.0).round() as u32;
            let rx = (modal_b.max_x() * 2.0).round() as u32 - 1;
            let hdr_y = ((modal_b.y + 24.0) * 2.0).round() as u32;
            let body_y = ((modal_b.y + 160.0) * 2.0).round() as u32;
            let ftr_y = ((modal_b.max_y() - 24.0) * 2.0).round() as u32;

            for x_col in [lx, lx + 1, rx - 1, rx] {
                let c_hdr = rgb_at(&rgba, pw, x_col, hdr_y);
                let c_body = rgb_at(&rgba, pw, x_col, body_y);
                let c_ftr = rgb_at(&rgba, pw, x_col, ftr_y);
                let diff_body = c_hdr[0].abs_diff(c_body[0]);
                let diff_ftr = c_hdr[0].abs_diff(c_ftr[0]);
                assert!(
                    diff_body <= 3 && diff_ftr <= 3,
                    "{kind} ({appearance:?}) border mismatch at x={x_col}: hdr={c_hdr:?}, body={c_body:?}, ftr={c_ftr:?}"
                );
            }
        }
    }
}

fn rgb_at(rgba: &[u8], pw: u32, x: u32, y: u32) -> [u8; 3] {
    let off = ((y * pw + x) * 4) as usize;
    [rgba[off], rgba[off + 1], rgba[off + 2]]
}

#[test]
fn single_line_fields_and_import_search_center_text_vertically_on_pixels() {
    let mut gpu = GpuRenderer::new_headless().expect("headless Metal GpuRenderer");
    let mut fx = make_fixture(Appearance::Light);
    fx.state.window_vibrant = false;
    let vp = Size::new(1000.0, 680.0);

    let mut imp = ImportSheetState::new();
    imp.scans = Some(Vec::new());
    fx.state.import_modal = Some(imp);
    fx.state.focus = Some(FocusTarget::ImportSearch);
    let _ = render_main_window(&mut fx.state, vp, 2.0, 3.0, &mut gpu);
    let (scene, _) = render_main_window(&mut fx.state, vp, 2.0, 3.5, &mut gpu);

    let tree = fx.state.last_tree.as_ref().expect("computed tree");
    let search_b = tree.bounds_by_id("importSearch").expect("importSearch bounds");
    let text_b = tree
        .bounds_by_id("importSearch-text")
        .expect("importSearch-text bounds");
    let layout_delta = (text_b.center().y - search_b.center().y).abs();
    assert!(
        layout_delta <= 1.0,
        "importSearch-text center ({:.2}) must align with importSearch center ({:.2}), delta={layout_delta:.2}",
        text_b.center().y,
        search_b.center().y
    );

    let (pw, _ph, rgba) = gpu
        .render_to_rgba(vp.width as u32, vp.height as u32, 2.0, &scene)
        .expect("render importSheet to rgba");

    let x0 = ((text_b.x + 2.0) * 2.0).round() as u32;
    let x1 = ((text_b.x + 180.0) * 2.0).round() as u32;
    let mid_x = ((search_b.x + search_b.width * 0.8) * 2.0).round() as u32;
    let mid_y = (search_b.center().y * 2.0).round() as u32;
    let bg = rgb_at(&rgba, pw, mid_x, mid_y);
    let span = |a: [u8; 3], b: [u8; 3]| -> u8 {
        a[0].abs_diff(b[0])
            .max(a[1].abs_diff(b[1]))
            .max(a[2].abs_diff(b[2]))
    };

    let top_in = (1..mid_y)
        .rev()
        .find(|&y| span(rgb_at(&rgba, pw, mid_x, y), bg) >= 12)
        .expect("search box top border")
        + 1;
    let bot_in = ((mid_y + 1)..(vp.height as u32 * 2 - 1))
        .find(|&y| span(rgb_at(&rgba, pw, mid_x, y), bg) >= 12)
        .expect("search box bottom border")
        - 1;
    let box_center_px = (top_in + bot_in) as f32 * 0.5;

    let mut row_ink = Vec::new();
    for y in (top_in + 3)..=(bot_in - 3) {
        let cnt = (x0..=x1)
            .filter(|&x| span(rgb_at(&rgba, pw, x, y), bg) >= 24)
            .count();
        row_ink.push((y, cnt));
    }
    let peak = row_ink.iter().map(|&(_, c)| c).max().unwrap_or(0);
    assert!(peak >= 4, "placeholder text must render visible ink");
    let floor = ((peak as f32) * 0.15).ceil() as usize;
    let first_y = row_ink.iter().find(|&&(_, c)| c >= floor).unwrap().0;
    let last_y = row_ink.iter().rfind(|&&(_, c)| c >= floor).unwrap().0;
    let ink_center_px = (first_y + last_y) as f32 * 0.5;
    let px_delta = (ink_center_px - box_center_px).abs();
    assert!(
        px_delta <= 3.5,
        "importSearch placeholder ink center ({ink_center_px:.1}px) off box center ({box_center_px:.1}px) by {px_delta:.1}px"
    );
}
