//! Headless Metal GPU render & Accessibility layout-gate tests across all Rota surfaces.
//! Never opens a visible window on the host (`GpuRenderer::new_headless()`).

use rota_core::model::Harness;
use rota_ui::{A11yEvent, Appearance, GpuRenderer, Size};

use crate::actions::{AppAction, SettingsPane, SidebarSelection};
use crate::app_state::{ImportSheetState, RoutineFormState};
use crate::render_test_fixture::make_fixture;
use crate::views::{audit_a11y_tree, render_main_window};

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

#[test]
fn headless_gpu_renders_all_surfaces_light_and_dark_at_1000x680_and_820x680_with_zero_violations() {
    let mut renderer = GpuRenderer::new_headless().expect("headless Metal GPU renderer");

    for appearance in [Appearance::Light, Appearance::Dark] {
        let mut fx = make_fixture(appearance);

        for width in [1000.0f32, 820.0f32] {
            let vp = Size::new(width, 680.0);

            // 1. SessionView (rich Markdown, table, fenced code, toolbar, sidebar)
            fx.state
                .execute_action(AppAction::SelectSession(fx.session_review_id));
            assert_eq!(fx.state.window_title(), "Daily code review");
            let (scene, a11y) = render_main_window(&mut fx.state, vp, 2.0, 1.0, &mut renderer);
            let violations = audit_a11y_tree(&a11y, vp);
            assert!(
                violations.is_empty(),
                "SessionView ({appearance:?}, {width}x680) violations: {violations:?}"
            );
            assert!(find_a11y(&a11y, "mainToolbar").is_some());
            assert!(find_a11y(&a11y, "scheduleButton").is_some());
            assert!(find_a11y(&a11y, "import").is_some());
            assert!(find_a11y(&a11y, "sidebarSettings").is_some());
            assert!(find_a11y(&a11y, "routineSidebar").is_some());
            assert!(find_a11y(&a11y, "showSessionRoutine").is_some());
            assert!(find_a11y(&a11y, "openTerminal").is_some());
            assert!(find_a11y(&a11y, "chatTranscript").is_some());
            assert!(find_a11y(&a11y, "transcriptCompletion").is_some());
            assert!(find_a11y(&a11y, "markdownTable").is_some());
            assert!(find_a11y(&a11y, "chatComposer").is_some());

            let (pw, ph, rgba) = renderer
                .render_to_rgba(width as u32, 680, 2.0, &scene)
                .expect("render SessionView");
            assert_eq!((pw, ph), ((width as u32) * 2, 1360));
            assert_eq!(rgba.len(), (pw * ph * 4) as usize);

            // 2. QuestionCard surface + option selection (`questionOption-format-short`)
            fx.state
                .execute_action(AppAction::SelectSession(fx.session_question_id));
            assert_eq!(fx.state.window_title(), "Weekly project report");
            let (_, q_a11y) = render_main_window(&mut fx.state, vp, 2.0, 1.2, &mut renderer);
            let opt_node = find_a11y(&q_a11y, "questionOption-format-short")
                .expect("questionOption-format-short present");
            let opt_act = opt_node.action.expect("option has action");
            fx.state
                .process_frame_inputs(&[], &[A11yEvent::Press(opt_act)], 2.0);
            let (q_scene, q_a11y_after) = render_main_window(&mut fx.state, vp, 2.0, 1.3, &mut renderer);
            let q_violations = audit_a11y_tree(&q_a11y_after, vp);
            assert!(
                q_violations.is_empty(),
                "QuestionCard ({appearance:?}, {width}x680) violations: {q_violations:?}"
            );
            assert!(find_a11y(&q_a11y_after, "questionCard").is_some());
            assert!(
                find_a11y(&q_a11y_after, "showQuestion").is_none(),
                "showQuestion banner must hide when questionCard fits 100% in chatTranscript"
            );
            assert!(find_a11y(&q_a11y_after, "answerQuestion-accept").is_some());
            renderer
                .render_to_rgba(width as u32, 680, 2.0, &q_scene)
                .expect("render QuestionCard");

            // 3. RoutineDetail surface (`showSessionRoutine` navigation)
            fx.state
                .execute_action(AppAction::ShowSessionRoutine("weekly-report".to_string()));
            assert_eq!(
                fx.state.selection,
                Some(SidebarSelection::Routine("weekly-report".into()))
            );
            let (rd_scene, rd_a11y) = render_main_window(&mut fx.state, vp, 2.0, 1.4, &mut renderer);
            let rd_violations = audit_a11y_tree(&rd_a11y, vp);
            assert!(
                rd_violations.is_empty(),
                "RoutineDetail ({appearance:?}, {width}x680) violations: {rd_violations:?}"
            );
            assert!(find_a11y(&rd_a11y, "routineEnabled").is_some());
            assert!(find_a11y(&rd_a11y, "runNow").is_some());
            assert!(find_a11y(&rd_a11y, "editRoutine").is_some());
            renderer
                .render_to_rgba(width as u32, 680, 2.0, &rd_scene)
                .expect("render RoutineDetail");

            // 4. ScheduleView surface
            fx.state.execute_action(AppAction::ToggleSchedule);
            assert_eq!(fx.state.window_title(), "Schedule");
            let (sc_scene, sc_a11y) = render_main_window(&mut fx.state, vp, 2.0, 1.5, &mut renderer);
            let sc_violations = audit_a11y_tree(&sc_a11y, vp);
            assert!(
                sc_violations.is_empty(),
                "ScheduleView ({appearance:?}, {width}x680) violations: {sc_violations:?}"
            );
            assert!(find_a11y(&sc_a11y, "scheduleView").is_some());
            renderer
                .render_to_rgba(width as u32, 680, 2.0, &sc_scene)
                .expect("render ScheduleView");

            // 5. SettingsView (`General`, `Chat`, `Agents`)
            for pane in SettingsPane::ALL {
                fx.state.execute_action(AppAction::OpenSettings(Some(pane)));
                assert_eq!(fx.state.window_title(), pane.title());
                let (st_scene, st_a11y) = render_main_window(&mut fx.state, vp, 2.0, 1.6, &mut renderer);
                let st_violations = audit_a11y_tree(&st_a11y, vp);
                assert!(
                    st_violations.is_empty(),
                    "Settings {:?} ({appearance:?}, {width}x680) violations: {st_violations:?}",
                    pane
                );
                renderer
                    .render_to_rgba(width as u32, 680, 2.0, &st_scene)
                    .expect("render SettingsView");
            }
            fx.state.execute_action(AppAction::CloseSettings);

            // 6. Modals (`RoutineForm` & `ImportSheet`) + Empty State
            fx.state.routine_modal = Some(RoutineFormState::new_default());
            let (rf_scene, rf_a11y) = render_main_window(&mut fx.state, vp, 2.0, 1.7, &mut renderer);
            assert!(audit_a11y_tree(&rf_a11y, vp).is_empty());
            assert!(find_a11y(&rf_a11y, "routineForm").is_some());
            assert!(find_a11y(&rf_a11y, "routineHarness").is_some());
            assert!(find_a11y(&rf_a11y, "routineRepeat").is_some());
            renderer
                .render_to_rgba(width as u32, 680, 2.0, &rf_scene)
                .expect("render RoutineForm");
            fx.state.routine_modal = None;

            let mut imp = ImportSheetState::new();
            imp.scans = Some(Vec::new());
            fx.state.import_modal = Some(imp);
            let (_, im_a11y) = render_main_window(&mut fx.state, vp, 2.0, 1.8, &mut renderer);
            assert!(audit_a11y_tree(&im_a11y, vp).is_empty());
            assert!(find_a11y(&im_a11y, "importSheet").is_some());
            fx.state.import_modal = None;
        }
    }
}

#[test]
fn unit_settings_form_and_menubar_panel_render_invariants() {
    let mut renderer = GpuRenderer::new_headless().expect("headless Metal GPU renderer");
    let mut fx = make_fixture(Appearance::Dark);

    // 1. SettingsStore scale stepping & persistence
    fx.state.settings.step_interface_scale(1);
    assert!((fx.state.settings.interface_scale - 1.1).abs() < 0.01);
    fx.state.settings.set_interface_scale(1.0);

    // 2. RoutineFormState default prompt generation & schedule building
    let mut form = RoutineFormState::new_default();
    form.skill_input.set_text("code-audit");
    form.folder_input.set_text("/tmp/project");
    form.sync_generated_prompt();
    assert!(!form.prompt_input.is_empty());
    let built = form.build_routine(None);
    assert_eq!(built.id, "code-audit");
    assert_eq!(built.schedule, "0 9 * * 1-5");

    // 3. MenuBarPanel 340x320 render & AX layout check
    let theme = fx.state.theme();
    let mut reg = crate::actions::ActionRegistry::new();
    let mut panel_map = Vec::new();
    let panel_root =
        crate::views::panel_view::build_panel_tree(&fx.state, &theme, 320.0, &mut reg, &mut panel_map);
    let panel_vp = Size::new(340.0, 320.0);
    let tree = rota_ui::ComputedUiTree::compute(&mut renderer.text, panel_root, panel_vp, 2.0);
    let mut scene = rota_ui::Scene::new(theme.elevated);
    let a11y = tree.paint(&mut renderer, &mut scene, 2.0);
    assert!(audit_a11y_tree(&a11y, panel_vp).is_empty());
    assert!(!panel_map.is_empty());
    let (pw, ph, _) = renderer
        .render_to_rgba(340, 320, 2.0, &scene)
        .expect("render menu bar panel");
    assert_eq!((pw, ph), (680, 640));
}

#[test]
fn ui_precision_and_editor_interaction_invariants() {
    use crate::actions::FocusTarget;
    use rota_ui::{EditKey, Modifiers, UiInputEvent};

    let mut renderer = GpuRenderer::new_headless().expect("headless Metal GPU renderer");
    let mut fx = make_fixture(Appearance::Light);
    let vp = Size::new(1000.0, 680.0);

    // 1. ImportSheet search box never crushes vertically (>= 32 pt)
    let mut imp = ImportSheetState::new();
    imp.scans = Some(Vec::new());
    fx.state.import_modal = Some(imp);
    let (_, im_a11y) = render_main_window(&mut fx.state, vp, 2.0, 2.0, &mut renderer);
    let search_node = find_a11y(&im_a11y, "importSearch").expect("importSearch present");
    assert!(
        search_node.bounds_in_window.height >= 32.0,
        "importSearch crushed to {} pt",
        search_node.bounds_in_window.height
    );
    fx.state.import_modal = None;

    // 2. QuestionCard custom editor preserves cursor across Left arrow + insert ("ac" -> Left -> "b" == "abc")
    fx.state
        .execute_action(AppAction::SelectSession(fx.session_question_id));
    fx.state.execute_action(AppAction::SelectQuestionOther {
        field_id: "format".to_string(),
    });
    assert_eq!(
        fx.state.focus,
        Some(FocusTarget::QuestionField("format".to_string()))
    );
    let mods = Modifiers::default();
    fx.state.process_frame_inputs(
        &[
            UiInputEvent::Key {
                key: EditKey::Text("ac".to_string()),
                modifiers: mods,
            },
            UiInputEvent::Key {
                key: EditKey::Left,
                modifiers: mods,
            },
            UiInputEvent::Key {
                key: EditKey::Text("b".to_string()),
                modifiers: mods,
            },
        ],
        &[],
        2.0,
    );
    let (_, q_a11y) = render_main_window(&mut fx.state, vp, 2.0, 2.1, &mut renderer);
    let q_field = find_a11y(&q_a11y, "questionField-format").expect("questionField-format present");
    assert_eq!(q_field.value.as_deref(), Some("abc"));

    // 3. Settings > Chat Quick Reply AXSetValue + Tab traversal
    fx.state
        .execute_action(AppAction::OpenSettings(Some(SettingsPane::Chat)));
    let _ = render_main_window(&mut fx.state, vp, 2.0, 2.2, &mut renderer);
    fx.state.process_frame_inputs(
        &[],
        &[
            A11yEvent::SetFocused {
                id: "quickReplyTitle-0".to_string(),
                action: None,
                focused: true,
            },
            A11yEvent::SetValue {
                id: "quickReplyTitle-0".to_string(),
                action: None,
                value: "Ship".to_string(),
            },
        ],
        2.0,
    );
    assert_eq!(fx.state.focus, Some(FocusTarget::QuickReplyTitle(0)));
    assert_eq!(fx.state.settings.quick_replies[0].title, "Ship");
    fx.state.process_frame_inputs(
        &[UiInputEvent::Key {
            key: EditKey::Tab,
            modifiers: mods,
        }],
        &[],
        2.0,
    );
    assert_eq!(fx.state.focus, Some(FocusTarget::QuickReplyMessage(0)));
    fx.state.process_frame_inputs(
        &[],
        &[A11yEvent::SetValue {
            id: "chatTextScale".to_string(),
            action: None,
            value: "1.25".to_string(),
        }],
        2.0,
    );
    assert!((fx.state.settings.chat_scale - 1.25).abs() < 0.01);
    fx.state.settings.set_chat_scale(1.0);
    fx.state.execute_action(AppAction::CloseSettings);

    // 4. RoutineForm Tab traversal + `AXMenu` popup selection
    fx.state.execute_action(AppAction::OpenNewRoutine);
    let (_, rf_a11y) = render_main_window(&mut fx.state, vp, 2.0, 2.3, &mut renderer);
    let h_popup = find_a11y(&rf_a11y, "routineHarness").expect("routineHarness popup");
    assert_eq!(h_popup.value.as_deref(), Some("Claude Code"));
    fx.state
        .process_frame_inputs(&[], &[A11yEvent::Press(h_popup.action.unwrap())], 2.0);
    let (_, rf_menu_a11y) = render_main_window(&mut fx.state, vp, 2.0, 2.4, &mut renderer);
    let shell_item = find_a11y(&rf_menu_a11y, "routineHarness-shell").expect("Shell menu item");
    fx.state
        .process_frame_inputs(&[], &[A11yEvent::Press(shell_item.action.unwrap())], 2.0);
    assert_eq!(
        fx.state.routine_modal.as_ref().map(|f| f.harness),
        Some(Harness::Shell)
    );
    assert_eq!(fx.state.focus, Some(FocusTarget::RoutineSkill));
    fx.state.process_frame_inputs(
        &[UiInputEvent::Key {
            key: EditKey::Tab,
            modifiers: mods,
        }],
        &[],
        2.0,
    );
    assert_eq!(fx.state.focus, Some(FocusTarget::RoutineName));
    fx.state.execute_action(AppAction::CloseModal);

    // 5. MenuBarPanel left/right edge alignment (0.0 pt delta between rows and footer buttons)
    let theme = fx.state.theme();
    let mut reg = crate::actions::ActionRegistry::new();
    let mut panel_map = Vec::new();
    let panel_root =
        crate::views::panel_view::build_panel_tree(&fx.state, &theme, 260.0, &mut reg, &mut panel_map);
    let tree = rota_ui::ComputedUiTree::compute(&mut renderer.text, panel_root, Size::new(340.0, 260.0), 2.0);
    let row_b = tree.bounds_by_id("panelRow-daily-review").expect("panelRow");
    let settings_b = tree.bounds_by_id("panelSettings").expect("panelSettings");
    let open_b = tree.bounds_by_id("panelOpenRota").expect("panelOpenRota");
    let quit_b = tree.bounds_by_id("panelQuit").expect("panelQuit");
    assert!(
        (row_b.x - settings_b.x).abs() <= 0.5,
        "panelSettings left edge {} != row left edge {}",
        settings_b.x,
        row_b.x
    );
    assert!(open_b.x > settings_b.max_x());
    assert!(
        (row_b.max_x() - quit_b.max_x()).abs() <= 0.5,
        "panelQuit right edge {} != row right edge {}",
        quit_b.max_x(),
        row_b.max_x()
    );
}

#[test]
fn tactile_mouse_up_cancellation_auto_grow_ime_and_markdown_links() {
    use crate::actions::FocusTarget;
    use rota_ui::{EditKey, Modifiers, MouseButton, Point, UiInputEvent};

    let mut renderer = rota_ui::GpuRenderer::new_headless().expect("Metal headless");
    let mut fx = make_fixture(Appearance::Light);
    let vp = Size::new(1000.0, 680.0);

    fx.state
        .execute_action(AppAction::SelectSession(fx.session_review_id));
    let (_, a11y0) = render_main_window(&mut fx.state, vp, 2.0, 1.0, &mut renderer);

    // 1. Clickable Markdown link chip emitted for `[build report](https://example.com/report)`.
    let link_node = a11y0
        .iter()
        .find_map(|n| find_prefix(n, "markdownLink-"))
        .expect("clickable markdownLink chip");
    assert_eq!(link_node.title, "Open build report");

    // 2. Native macOS `MouseUp` button semantics: press on `newRoutine`, drag away, release -> canceled!
    let new_btn = find_a11y(&a11y0, "newRoutine").expect("newRoutine");
    let btn_center = new_btn.bounds_in_window.center();
    fx.state.process_frame_inputs_at(
        &[UiInputEvent::PointerDown {
            pos: btn_center,
            button: MouseButton::Left,
            click_count: 1,
        }],
        &[],
        2.0,
        1.1,
    );
    assert_eq!(fx.state.pressed_id.as_deref(), Some("newRoutine"));
    assert!(
        fx.state.routine_modal.is_none(),
        "button must not fire on MouseDown"
    );

    fx.state.process_frame_inputs_at(
        &[
            UiInputEvent::PointerMoved(Point::new(50.0, 50.0)),
            UiInputEvent::PointerUp {
                pos: Point::new(50.0, 50.0),
                button: MouseButton::Left,
            },
        ],
        &[],
        2.0,
        1.2,
    );
    assert!(
        fx.state.routine_modal.is_none(),
        "releasing outside button bounds must cancel click"
    );

    // Press and release INSIDE `newRoutine` -> opens modal!
    fx.state.process_frame_inputs_at(
        &[
            UiInputEvent::PointerDown {
                pos: btn_center,
                button: MouseButton::Left,
                click_count: 1,
            },
            UiInputEvent::PointerUp {
                pos: btn_center,
                button: MouseButton::Left,
            },
        ],
        &[],
        2.0,
        1.3,
    );
    assert!(
        fx.state.routine_modal.is_some(),
        "releasing inside button bounds must activate button"
    );
    fx.state.execute_action(AppAction::CloseModal);

    // 3. Auto-growing multi-line composer + IME preedit & cursor anchor rect.
    let (_, a11y_base) = render_main_window(&mut fx.state, vp, 2.0, 1.4, &mut renderer);
    let base_comp_h = find_a11y(&a11y_base, "composer")
        .expect("composer")
        .bounds_in_window
        .height;
    fx.state.focus = Some(FocusTarget::Composer);
    fx.state.process_frame_inputs_at(
        &[
            UiInputEvent::Key {
                key: EditKey::Text("line1\nline2\nline3\nline4".to_string()),
                modifiers: Modifiers::default(),
            },
            UiInputEvent::ImePreedit("かな".to_string()),
        ],
        &[],
        2.0,
        1.5,
    );
    let (_, a11y_grown) = render_main_window(&mut fx.state, vp, 2.0, 1.5, &mut renderer);
    let grown_comp_h = find_a11y(&a11y_grown, "composer")
        .expect("composer")
        .bounds_in_window
        .height;
    assert!(
        grown_comp_h > base_comp_h + 40.0,
        "multi-line draft should expand composer ({grown_comp_h} vs {base_comp_h})"
    );
    assert!(
        fx.state.last_ime_cursor_rect.is_some(),
        "focused composer must publish IME cursor rect"
    );
}

fn find_prefix<'a>(node: &'a rota_ui::A11yNode, prefix: &str) -> Option<&'a rota_ui::A11yNode> {
    if node.id.starts_with(prefix) {
        return Some(node);
    }
    node.children.iter().find_map(|c| find_prefix(c, prefix))
}
