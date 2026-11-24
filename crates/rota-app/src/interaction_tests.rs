//! End-to-end pointer-coordinate (`hit_test` + `PointerDown` / `PointerMoved` / `PointerUp` / `Wheel`) interaction tests.

use rota_ui::{
    Appearance, CursorKind, EditKey, GpuRenderer, Modifiers, MouseButton, MouseScrollDelta, Point, Size,
    TouchPhase, UiInputEvent,
};

use crate::actions::{FocusTarget, SettingsPane, ShellEvent, SidebarSelection};
use crate::app_state::AppState;
use crate::render_test_fixture::make_fixture;
use crate::views::render_main_window;

fn pump(state: &mut AppState, gpu: &mut GpuRenderer, vp: Size, events: &[UiInputEvent], t: f64) {
    state.process_frame_inputs_at(events, &[], 2.0, t);
    let _ = state.drain_shell_events();
    let _ = render_main_window(state, vp, 2.0, t, gpu);
}

fn center_of(state: &AppState, id: &str) -> Point {
    state
        .last_tree
        .as_ref()
        .and_then(|t| t.bounds_by_id(id))
        .unwrap_or_else(|| panic!("missing element bounds for `{id}`"))
        .center()
}

fn click_id(state: &mut AppState, gpu: &mut GpuRenderer, vp: Size, id: &str, t: f64) {
    let pt = center_of(state, id);
    pump(
        state,
        gpu,
        vp,
        &[
            UiInputEvent::PointerMoved(pt),
            UiInputEvent::PointerDown {
                pos: pt,
                button: MouseButton::Left,
                click_count: 1,
            },
        ],
        t,
    );
    pump(
        state,
        gpu,
        vp,
        &[UiInputEvent::PointerUp {
            pos: pt,
            button: MouseButton::Left,
        }],
        t + 0.02,
    );
}

#[test]
fn mouse_drag_and_click_chat_text_scale_slider_works() {
    let mut gpu = GpuRenderer::new_headless().expect("headless Metal GpuRenderer");
    let mut fx = make_fixture(Appearance::Light);
    let vp = Size::new(1000.0, 680.0);

    pump(&mut fx.state, &mut gpu, vp, &[], 1.0);

    // Open Settings via real mouse click on sidebar footer button, then select Chat pane.
    click_id(&mut fx.state, &mut gpu, vp, "sidebarSettings", 1.1);
    assert_eq!(fx.state.settings_pane, Some(SettingsPane::General));
    click_id(&mut fx.state, &mut gpu, vp, "settingsPane-chat", 1.2);
    assert_eq!(fx.state.settings_pane, Some(SettingsPane::Chat));

    let slider_bounds = fx
        .state
        .last_tree
        .as_ref()
        .and_then(|t| t.bounds_by_id("chatTextScale"))
        .expect("chatTextScale bounds");
    let hit = fx
        .state
        .last_tree
        .as_ref()
        .and_then(|t| t.hit_test(slider_bounds.center()))
        .expect("chatTextScale must be hit-testable by mouse");
    assert_eq!(hit.id.as_deref(), Some("chatTextScale"));
    assert_eq!(hit.cursor, CursorKind::PointingHand);

    // Click near right edge -> 200% (2.0), drag to middle -> ~135% (1.35), drag to left -> 70% (0.70).
    let right_pt = Point::new(slider_bounds.max_x() - 4.0, slider_bounds.center().y);
    let mid_pt = slider_bounds.center();
    let left_pt = Point::new(slider_bounds.x + 4.0, slider_bounds.center().y);

    pump(
        &mut fx.state,
        &mut gpu,
        vp,
        &[UiInputEvent::PointerDown {
            pos: right_pt,
            button: MouseButton::Left,
            click_count: 1,
        }],
        1.3,
    );
    assert!((fx.state.settings.chat_scale - 2.0).abs() < 0.01);

    pump(
        &mut fx.state,
        &mut gpu,
        vp,
        &[UiInputEvent::PointerMoved(mid_pt)],
        1.35,
    );
    assert!((fx.state.settings.chat_scale - 1.35).abs() <= 0.06);

    pump(
        &mut fx.state,
        &mut gpu,
        vp,
        &[
            UiInputEvent::PointerMoved(left_pt),
            UiInputEvent::PointerUp {
                pos: left_pt,
                button: MouseButton::Left,
            },
        ],
        1.4,
    );
    assert!((fx.state.settings.chat_scale - 0.70).abs() < 0.01);

    // Keyboard arrow key while slider is focused steps by +5%.
    pump(
        &mut fx.state,
        &mut gpu,
        vp,
        &[UiInputEvent::Key {
            key: EditKey::Right,
            modifiers: Modifiers::default(),
        }],
        1.45,
    );
    assert!((fx.state.settings.chat_scale - 0.75).abs() < 0.01);

    // Pressing Reset and releasing OUTSIDE bounds cancels; clicking inside resets to 100%.
    let rst_pt = center_of(&fx.state, "chatScaleReset");
    pump(
        &mut fx.state,
        &mut gpu,
        vp,
        &[
            UiInputEvent::PointerDown {
                pos: rst_pt,
                button: MouseButton::Left,
                click_count: 1,
            },
            UiInputEvent::PointerUp {
                pos: Point::new(10.0, 10.0),
                button: MouseButton::Left,
            },
        ],
        1.5,
    );
    assert!((fx.state.settings.chat_scale - 0.75).abs() < 0.01);

    click_id(&mut fx.state, &mut gpu, vp, "chatScaleReset", 1.6);
    assert!((fx.state.settings.chat_scale - 1.0).abs() < 0.01);
}

#[test]
fn mouse_scrollbar_drag_and_wheel_reach_exact_bottom() {
    let mut gpu = GpuRenderer::new_headless().expect("headless Metal GpuRenderer");
    let mut fx = make_fixture(Appearance::Dark);
    let vp = Size::new(820.0, 520.0);

    fx.state.settings_pane = Some(SettingsPane::Agents);
    pump(&mut fx.state, &mut gpu, vp, &[], 2.0);

    let thumb = fx
        .state
        .last_tree
        .as_ref()
        .and_then(|t| t.bounds_by_id("scrollbarThumb-settings-agents"))
        .expect("settings-agents scrollbar thumb bounds");
    let start = thumb.center();
    let dragged = Point::new(start.x, start.y + 180.0);

    pump(
        &mut fx.state,
        &mut gpu,
        vp,
        &[
            UiInputEvent::PointerMoved(start),
            UiInputEvent::PointerDown {
                pos: start,
                button: MouseButton::Left,
                click_count: 1,
            },
            UiInputEvent::PointerMoved(dragged),
            UiInputEvent::PointerUp {
                pos: dragged,
                button: MouseButton::Left,
            },
        ],
        2.1,
    );
    assert!(
        fx.state.settings_scroll.scroll_y > 80.0,
        "dragging scrollbar thumb must advance scroll_y, got {}",
        fx.state.settings_scroll.scroll_y
    );

    // Switch to SessionView and verify mouse wheel reaches true bottom of chatTranscript.
    fx.state.settings_pane = None;
    fx.state.selection = Some(SidebarSelection::Session(fx.session_review_id));
    fx.state.refresh_session_transcript(fx.session_review_id, false);
    pump(&mut fx.state, &mut gpu, vp, &[], 2.2);

    let tr_vp = fx
        .state
        .last_tree
        .as_ref()
        .and_then(|t| t.bounds_by_id("chatTranscript"))
        .expect("chatTranscript bounds");
    pump(
        &mut fx.state,
        &mut gpu,
        vp,
        &[
            UiInputEvent::PointerMoved(tr_vp.center()),
            UiInputEvent::Wheel {
                delta: MouseScrollDelta::LineDelta(0.0, -40.0),
                phase: TouchPhase::Moved,
            },
        ],
        2.3,
    );
    let tr = fx.state.transcripts.get(&fx.session_review_id).unwrap();
    let expected_max = tr.scroll.max_scroll_y(tr_vp.height);
    assert!(
        (tr.scroll.scroll_y - expected_max).abs() <= 1.5,
        "wheel scroll must reach exact bottom {expected_max}, got {}",
        tr.scroll.scroll_y
    );
}

#[test]
fn mouse_hover_transcript_question_other_and_edit_menu_commands_work() {
    let mut gpu = GpuRenderer::new_headless().expect("headless Metal GpuRenderer");
    let mut fx = make_fixture(Appearance::Light);
    let vp = Size::new(1000.0, 680.0);

    fx.state.selection = Some(SidebarSelection::Session(fx.session_review_id));
    fx.state.refresh_session_transcript(fx.session_review_id, false);
    pump(&mut fx.state, &mut gpu, vp, &[], 3.0);

    // Scroll to top of transcript so `selBlock-0-0` (first user message) is inside `chatTranscript` clip rect.
    let tr_center = center_of(&fx.state, "chatTranscript");
    pump(
        &mut fx.state,
        &mut gpu,
        vp,
        &[
            UiInputEvent::PointerMoved(tr_center),
            UiInputEvent::Wheel {
                delta: MouseScrollDelta::LineDelta(0.0, 30.0),
                phase: TouchPhase::Moved,
            },
        ],
        3.05,
    );

    // Hover user bubble -> IBeam cursor and copyUser icon revealed.
    let user_pt = center_of(&fx.state, "selBlock-0-0");
    let hit = fx
        .state
        .last_tree
        .as_ref()
        .and_then(|t| t.hit_test(user_pt))
        .expect("user bubble text hit");
    assert_eq!(hit.cursor, CursorKind::IBeam);
    pump(
        &mut fx.state,
        &mut gpu,
        vp,
        &[UiInputEvent::PointerMoved(user_pt)],
        3.1,
    );
    assert_eq!(fx.state.hovered_id.as_deref(), Some("selBlock-0-0"));

    // Select question session, click "Something else…", type custom answer, verify Submit enables.
    let q_row = format!(
        "sessionRow-{}",
        rota_core::model::serde_ext::uppercase_uuid(fx.session_question_id)
    );
    click_id(&mut fx.state, &mut gpu, vp, &q_row, 3.2);
    click_id(&mut fx.state, &mut gpu, vp, "questionOther-format", 3.3);
    assert_eq!(
        fx.state.focus,
        Some(FocusTarget::QuestionField("format".to_string()))
    );

    pump(
        &mut fx.state,
        &mut gpu,
        vp,
        &[UiInputEvent::Key {
            key: EditKey::Text("Concise bullet digest".to_string()),
            modifiers: Modifiers::default(),
        }],
        3.4,
    );
    let _ = fx.state.shell_tx.send(ShellEvent::EditCommand(EditKey::Undo));
    pump(&mut fx.state, &mut gpu, vp, &[], 3.45);
    let _ = fx.state.shell_tx.send(ShellEvent::EditCommand(EditKey::Redo));
    pump(&mut fx.state, &mut gpu, vp, &[], 3.5);

    let draft_ans = fx
        .state
        .transcripts
        .get(&fx.session_question_id)
        .and_then(|t| t.question_drafts.get("report-format"))
        .and_then(|d| d.other.get("format"))
        .map(String::as_str);
    assert_eq!(draft_ans, Some("Concise bullet digest"));

    // Open New Routine via toolbar button, scroll modal down to Limits, toggle time limit, step +5 min, and close via Cancel.
    click_id(&mut fx.state, &mut gpu, vp, "newRoutine", 3.6);
    assert!(fx.state.routine_modal.is_some());
    let modal_sc = center_of(&fx.state, "routineFormScroll");
    pump(
        &mut fx.state,
        &mut gpu,
        vp,
        &[
            UiInputEvent::PointerMoved(modal_sc),
            UiInputEvent::Wheel {
                delta: MouseScrollDelta::LineDelta(0.0, -25.0),
                phase: TouchPhase::Moved,
            },
        ],
        3.65,
    );
    click_id(&mut fx.state, &mut gpu, vp, "routineTimeLimit", 3.7);
    pump(
        &mut fx.state,
        &mut gpu,
        vp,
        &[UiInputEvent::Wheel {
            delta: MouseScrollDelta::LineDelta(0.0, -10.0),
            phase: TouchPhase::Moved,
        }],
        3.75,
    );
    assert_eq!(
        fx.state.routine_modal.as_ref().and_then(|m| m.time_limit_minutes),
        Some(60)
    );
    click_id(&mut fx.state, &mut gpu, vp, "tlPlus", 3.8);
    assert_eq!(
        fx.state.routine_modal.as_ref().and_then(|m| m.time_limit_minutes),
        Some(65)
    );
    click_id(&mut fx.state, &mut gpu, vp, "Cancel", 3.9);
    assert!(fx.state.routine_modal.is_none());
}
