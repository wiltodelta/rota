//! Rota 120 Hz Metal / `wgpu 30` desktop & menu bar application entry point.

pub mod action_handlers;
pub mod actions;
pub mod app_state;
pub mod drag_drop;
pub mod editor_keys;
pub mod form_state;
pub mod input_dispatch;
pub mod menu_validation;
pub mod menus_macos;
pub mod panel_macos;
pub mod pointer_dispatch;
pub mod popup_macos;
pub mod settings_store;
pub mod shell_dispatch;
pub mod shell_macos;
pub mod views;

#[cfg(test)]
mod audit_fix_tests;
#[cfg(test)]
mod interaction_tests;
#[cfg(test)]
mod render_test_fixture;
#[cfg(test)]
mod render_tests;

use std::sync::Arc;
use std::sync::mpsc::{Receiver, channel};

use rota_core::storage::StorageLocation;
use rota_core::{PerformanceDiagnostics, Scheduler, SchedulerNotifier};
use rota_platform::{
    Logger, NotificationPayload, NotificationUserEvent, SystemNotifier, SystemUpdater,
    register_bundled_fonts, standard_preferences,
};
use rota_ui::{
    Appearance, CursorKind, FrameContext, FrameOutput, RotaWindowDelegate, Size, WindowAppearance,
    WindowConfig, WindowRunner,
};

use crate::actions::{AppAction, SettingsPane, ShellEvent};
use crate::app_state::AppState;
use crate::form_state::RoutineFormState;
use crate::settings_store::SettingsStore;
use crate::shell_macos::{MacShell, activate_existing_instance_and_exit_if_running, wake_app_event_loop};

const LOG: Logger = Logger::new("app");

struct AppSchedulerNotifier {
    system_notifier: SystemNotifier,
}

impl SchedulerNotifier for AppSchedulerNotifier {
    fn notify(&self, payload: NotificationPayload) {
        wake_app_event_loop();
        self.system_notifier.post(payload);
    }
}

struct RotaAppDelegate {
    state: AppState,
    shell: Option<MacShell>,
    notif_rx: Receiver<NotificationUserEvent>,
    _control_server: rota_core::ControlServerHandle,
}

impl RotaWindowDelegate for RotaAppDelegate {
    fn on_resumed(&mut self) {
        if let Some(shell) = self.shell.as_ref() {
            shell.ensure_main_menu();
        }
    }

    fn render_frame(&mut self, ctx: FrameContext<'_>) -> FrameOutput {
        self.state.modifiers = ctx.modifiers;
        self.state.now_seconds = ctx.now_seconds;
        #[cfg(target_os = "macos")]
        {
            let vibrant = !rota_ui::window_macos::macos_reduce_transparency();
            self.state.window_vibrant = vibrant;
            self.state.high_contrast = rota_ui::window_macos::macos_increase_contrast();
            self.state
                .activity_clock
                .set_reduce_motion(rota_ui::window_macos::macos_reduce_motion());
            rota_ui::window_macos::sync_macos_window_vibrancy(ctx.window, vibrant);
        }
        if let Some((_, copied_at)) = self.state.copied_feedback
            && ctx.now_seconds - copied_at >= 1.5
        {
            self.state.copied_feedback = None;
        }
        self.state
            .process_frame_inputs_at(ctx.events, ctx.a11y_events, ctx.scale_factor, ctx.now_seconds);
        while let Ok(nev) = self.notif_rx.try_recv() {
            let _ = self.state.shell_tx.send(ShellEvent::Notification(nev));
        }
        let _ = self.state.drain_shell_events();

        let (scene, a11y_nodes) = views::render_main_window(
            &mut self.state,
            ctx.viewport_size,
            ctx.scale_factor,
            ctx.now_seconds,
            ctx.renderer,
        );

        if let Some(shell) = self.shell.as_mut() {
            shell.sync(&mut self.state);
        }

        let cursor = if self.state.dragging_splitter {
            CursorKind::ResizeColumn
        } else {
            ctx.pointer_pos
                .and_then(|pt| self.state.last_tree.as_ref()?.hit_test(pt))
                .map_or(CursorKind::Arrow, |h| h.cursor)
        };

        let start_window_drag = std::mem::take(&mut self.state.pending_window_drag);
        let animate = self.state.activity_clock.needs_continuous_redraw();
        let copy_wake = self.state.copied_feedback.as_ref().map(|(_, copied_at)| {
            std::time::Duration::from_secs_f64((1.52 - (ctx.now_seconds - copied_at)).clamp(0.05, 1.55))
        });
        let caret_wake = (!animate
            && self.state.window_focused
            && self.state.has_focused_editor()
            && !self.state.activity_clock.reduce_motion)
            .then_some(std::time::Duration::from_millis(530));
        let next_wakeup_after = match (copy_wake, caret_wake) {
            (Some(a), Some(b)) => Some(a.min(b)),
            (Some(a), None) => Some(a),
            (None, b) => b,
        };

        FrameOutput {
            scene,
            a11y_nodes,
            cursor,
            animate_continuously: animate,
            next_wakeup_after,
            ime_cursor_rect: self.state.last_ime_cursor_rect,
            appearance: Some(self.state.window_appearance()),
            visible: Some(self.state.main_window_visible),
            title: Some(self.state.window_title()),
            start_window_drag,
        }
    }

    fn on_after_frame(&mut self, window: &rota_ui::NativeWindow) -> bool {
        popup_macos::dispatch_pending_popup(window, &mut self.state)
    }

    fn on_idle_poll(&mut self) -> bool {
        let mut dirty = false;
        while let Ok(nev) = self.notif_rx.try_recv() {
            let _ = self.state.shell_tx.send(ShellEvent::Notification(nev));
            dirty = true;
        }
        dirty |= self.state.drain_shell_events();
        if dirty && let Some(shell) = self.shell.as_mut() {
            shell.sync(&mut self.state);
        }
        dirty
    }
}

fn parse_env_appearance() -> (Option<Appearance>, WindowAppearance) {
    match std::env::var("ROTA_APPEARANCE")
        .unwrap_or_default()
        .trim()
        .to_ascii_lowercase()
        .as_str()
    {
        "light" => (Some(Appearance::Light), WindowAppearance::Light),
        "dark" => (Some(Appearance::Dark), WindowAppearance::Dark),
        _ => (None, WindowAppearance::System),
    }
}

fn main() {
    activate_existing_instance_and_exit_if_running();
    register_bundled_fonts();
    SystemUpdater::start();
    let _ = PerformanceDiagnostics::shared();

    let (appearance_override, win_appearance) = parse_env_appearance();
    let env_open_panel = std::env::var("ROTA_OPEN_PANEL").is_ok_and(|v| !v.is_empty() && v != "0");
    let env_open_main = std::env::var("ROTA_OPEN_MAIN").is_ok_and(|v| !v.is_empty() && v != "0");
    let env_open_edit = std::env::var("ROTA_OPEN_EDIT").is_ok_and(|v| !v.is_empty() && v != "0");
    let env_background = std::env::var("ROTA_BACKGROUND").is_ok_and(|v| !v.is_empty() && v != "0");
    let env_open_settings = std::env::var("ROTA_OPEN_SETTINGS").ok().filter(|s| !s.is_empty());

    let (notif_tx, notif_rx) = channel();
    let notifier: Arc<dyn SchedulerNotifier> = Arc::new(AppSchedulerNotifier {
        system_notifier: SystemNotifier::new(Some(notif_tx)),
    });

    let location = StorageLocation::standard();
    let (scheduler, control_handle) = match Scheduler::start_standard(location, Some(notifier)) {
        Ok(pair) => pair,
        Err(err) => {
            LOG.error(&format!("Failed to initialize Scheduler: {err}"));
            std::process::exit(1);
        }
    };

    let settings = SettingsStore::load(standard_preferences());
    let mut state = AppState::new(scheduler, settings, appearance_override);
    #[cfg(target_os = "macos")]
    {
        state.window_vibrant = !rota_ui::window_macos::macos_reduce_transparency();
    }
    state.spawn_agent_discovery();

    // Determine initial window presentation from environment hooks & stored state
    if let Some(pane_raw) = env_open_settings {
        let pane = SettingsPane::parse(&pane_raw).unwrap_or(state.settings.last_settings_pane);
        state.execute_action(AppAction::OpenSettings(Some(pane)));
    } else if env_open_edit {
        state.main_window_visible = true;
        if let Some(routine) = state.routines.first().cloned() {
            state.selection = Some(crate::actions::SidebarSelection::Routine(routine.id.clone()));
            state.routine_modal = Some(RoutineFormState::from_existing(&routine));
        }
    } else if env_open_main || (state.routines.is_empty() && !env_open_panel && !env_background) {
        state.main_window_visible = true;
    }

    let initial_title = state.window_title();
    let shell = MacShell::new(state.shell_tx.clone(), env_open_panel);

    let wake_sched = state.scheduler.clone();
    std::thread::spawn(move || {
        let mut last_rev = wake_sched.revision();
        loop {
            std::thread::sleep(std::time::Duration::from_millis(400));
            let cur_rev = wake_sched.revision();
            let any_running = wake_sched.routines().iter().any(|r| wake_sched.is_running(&r.id));
            if cur_rev != last_rev || any_running {
                last_rev = cur_rev;
                wake_app_event_loop();
            }
        }
    });

    let main_cfg = WindowConfig {
        title: initial_title,
        initial_size: Size::new(state.settings.window_width, state.settings.window_height),
        min_size: Size::new(820.0, 520.0),
        appearance: win_appearance,
        decorations: true,
        resizable: true,
        fullsize_content_view: true,
        vibrant: true,
        initial_visible: state.main_window_visible,
        exit_on_close: false,
    };

    let delegate = RotaAppDelegate {
        state,
        shell,
        notif_rx,
        _control_server: control_handle,
    };
    if let Err(err) = WindowRunner::new(delegate, main_cfg).run() {
        LOG.error(&format!("Application loop exited with error: {err}"));
        std::process::exit(1);
    }
}
