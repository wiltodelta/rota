//! `winit 0.30` 120 Hz ProMotion application loop, secondary panel surfaces, activity motion, & macOS Aqua appearance.

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::Arc;
use std::time::{Duration, Instant};

use winit::application::ApplicationHandler;
use winit::dpi::{LogicalPosition, LogicalSize, PhysicalPosition};
use winit::event::{ElementState, Ime, MouseButton, MouseScrollDelta, TouchPhase, WindowEvent};
use winit::event_loop::{ActiveEventLoop, ControlFlow, EventLoop};
use winit::window::{CursorIcon, Window, WindowAttributes, WindowId};

use crate::a11y::{A11yActionQueue, A11yEvent, A11yNode, sync_window_a11y};
use crate::element::CursorKind;
use crate::geometry::{Point, Rect, Size};
use crate::renderer::{GpuRenderer, WindowSurface};
use crate::scene::Scene;
use crate::text_input::{EditKey, Modifiers};
pub use crate::window_types::{ActivityClock, WindowAppearance, WindowConfig};

#[derive(Debug, Clone)]
pub enum UiInputEvent {
    PointerMoved(Point),
    PointerDown {
        pos: Point,
        button: MouseButton,
        click_count: u8,
    },
    PointerUp {
        pos: Point,
        button: MouseButton,
    },
    Wheel {
        delta: MouseScrollDelta,
        phase: TouchPhase,
    },
    Key {
        key: EditKey,
        modifiers: Modifiers,
    },
    ImePreedit(String),
    FileHovered(bool),
    FileDropped(PathBuf),
    Resized(Size),
    Focused(bool),
    CloseRequested,
}

pub struct FrameContext<'a> {
    pub window: &'a Window,
    pub window_id: WindowId,
    pub is_main_window: bool,
    pub viewport_size: Size,
    pub scale_factor: f32,
    pub modifiers: Modifiers,
    pub pointer_pos: Option<Point>,
    pub events: &'a [UiInputEvent],
    pub a11y_events: &'a [A11yEvent],
    pub now_seconds: f64,
    pub renderer: &'a mut GpuRenderer,
}

pub struct FrameOutput {
    pub scene: Scene,
    pub a11y_nodes: Vec<A11yNode>,
    pub cursor: CursorKind,
    pub animate_continuously: bool,
    pub next_wakeup_after: Option<Duration>,
    pub ime_cursor_rect: Option<Rect>,
    pub appearance: Option<WindowAppearance>,
    pub visible: Option<bool>,
    pub title: Option<String>,
    pub start_window_drag: bool,
}

pub trait RotaWindowDelegate {
    fn on_resumed(&mut self) {}
    fn render_frame(&mut self, ctx: FrameContext<'_>) -> FrameOutput;
    fn on_after_frame(&mut self, _window: &Window) -> bool {
        false
    }
    fn on_idle_poll(&mut self) -> bool {
        false
    }
}

struct ManagedWindow {
    window: Arc<Window>,
    surface: WindowSurface,
    is_main: bool,
    pointer_pos: Option<Point>,
    pending_events: Vec<UiInputEvent>,
    a11y_queue: A11yActionQueue,
    last_click: Option<(Instant, Point, u8)>,
    current_cursor: CursorKind,
    current_visible: bool,
    current_title: String,
    continuous_redraw: bool,
    next_wakeup: Option<Instant>,
    last_ime_rect: Option<Rect>,
}

pub struct WindowRunner<D: RotaWindowDelegate> {
    delegate: D,
    main_config: WindowConfig,
    renderer: Option<GpuRenderer>,
    windows: HashMap<WindowId, ManagedWindow>,
    modifiers: Modifiers,
    boot_instant: Instant,
}

impl<D: RotaWindowDelegate> WindowRunner<D> {
    pub fn new(delegate: D, main_config: WindowConfig) -> Self {
        Self {
            delegate,
            main_config,
            renderer: None,
            windows: HashMap::new(),
            modifiers: Modifiers::default(),
            boot_instant: Instant::now(),
        }
    }

    pub fn run(mut self) -> Result<(), String> {
        #[cfg(target_os = "macos")]
        let event_loop = {
            use winit::platform::macos::EventLoopBuilderExtMacOS;
            EventLoop::builder()
                .with_default_menu(false)
                .build()
                .map_err(|e| format!("EventLoop init failed: {e}"))?
        };
        #[cfg(not(target_os = "macos"))]
        let event_loop = EventLoop::new().map_err(|e| format!("EventLoop init failed: {e}"))?;
        event_loop.set_control_flow(ControlFlow::Wait);
        event_loop
            .run_app(&mut self)
            .map_err(|e| format!("EventLoop terminated with error: {e}"))
    }

    pub fn open_secondary_window(
        &mut self,
        event_loop: &ActiveEventLoop,
        config: WindowConfig,
    ) -> Result<WindowId, String> {
        let renderer = self.renderer.as_mut().ok_or("Renderer not initialized")?;
        let win = Arc::new(
            event_loop
                .create_window(build_window_attrs(&config))
                .map_err(|e| format!("Create secondary window failed: {e}"))?,
        );
        apply_macos_appearance(&win, config.appearance);
        let surface = renderer.create_secondary_surface(win.clone())?;
        #[cfg(target_os = "macos")]
        if config.initial_visible {
            crate::window_macos::activate_macos_window(&win);
        }
        let id = win.id();
        win.set_ime_allowed(true);
        let a11y_queue = new_a11y_queue(&win);
        self.windows.insert(
            id,
            ManagedWindow {
                window: win,
                surface,
                is_main: false,
                pointer_pos: None,
                pending_events: Vec::new(),
                a11y_queue,
                last_click: None,
                current_cursor: CursorKind::Arrow,
                current_visible: config.initial_visible,
                current_title: config.title,
                continuous_redraw: false,
                next_wakeup: None,
                last_ime_rect: None,
            },
        );
        Ok(id)
    }
}

fn new_a11y_queue(win: &Arc<Window>) -> A11yActionQueue {
    let q = A11yActionQueue::new();
    let wake = Arc::downgrade(win);
    q.set_waker(Arc::new(move || {
        if let Some(w) = wake.upgrade() {
            w.request_redraw();
        }
    }));
    q
}

impl<D: RotaWindowDelegate> ApplicationHandler for WindowRunner<D> {
    fn resumed(&mut self, event_loop: &ActiveEventLoop) {
        if self.renderer.is_some() {
            return;
        }
        let Ok(win_raw) = event_loop.create_window(build_window_attrs(&self.main_config)) else {
            event_loop.exit();
            return;
        };
        let win = Arc::new(win_raw);
        win.set_ime_allowed(true);
        configure_macos_window_chrome(&win, &self.main_config);
        apply_macos_appearance(&win, self.main_config.appearance);
        let Ok((renderer, surface)) = GpuRenderer::new_with_window(win.clone()) else {
            event_loop.exit();
            return;
        };
        #[cfg(target_os = "macos")]
        if self.main_config.vibrant {
            crate::window_macos::ensure_metal_layer_non_opaque(&win);
        }
        #[cfg(target_os = "macos")]
        if self.main_config.initial_visible {
            crate::window_macos::activate_macos_window(&win);
        }
        let id = win.id();
        let a11y_queue = new_a11y_queue(&win);
        win.request_redraw();
        self.renderer = Some(renderer);
        self.windows.insert(
            id,
            ManagedWindow {
                window: win,
                surface,
                is_main: true,
                pointer_pos: None,
                pending_events: Vec::new(),
                a11y_queue,
                last_click: None,
                current_cursor: CursorKind::Arrow,
                current_visible: self.main_config.initial_visible,
                current_title: self.main_config.title.clone(),
                continuous_redraw: false,
                next_wakeup: None,
                last_ime_rect: None,
            },
        );
        self.delegate.on_resumed();
    }

    fn window_event(&mut self, event_loop: &ActiveEventLoop, window_id: WindowId, event: WindowEvent) {
        match event {
            WindowEvent::ModifiersChanged(m) => {
                let st = m.state();
                self.modifiers = Modifiers {
                    cmd: st.super_key(),
                    shift: st.shift_key(),
                    alt: st.alt_key(),
                    ctrl: st.control_key(),
                };
            }
            WindowEvent::RedrawRequested => {
                let (Some(renderer), Some(mw)) = (self.renderer.as_mut(), self.windows.get_mut(&window_id))
                else {
                    return;
                };
                let sf = mw.window.scale_factor() as f32;
                let phys = mw.window.inner_size();
                mw.surface.resize(renderer.device(), phys.width, phys.height);
                let viewport = Size::new(phys.width as f32 / sf.max(1.0), phys.height as f32 / sf.max(1.0));
                let events = std::mem::take(&mut mw.pending_events);
                let a11y_events = mw.a11y_queue.drain();
                let out = self.delegate.render_frame(FrameContext {
                    window: &mw.window,
                    window_id,
                    is_main_window: mw.is_main,
                    viewport_size: viewport,
                    scale_factor: sf,
                    modifiers: self.modifiers,
                    pointer_pos: mw.pointer_pos,
                    events: &events,
                    a11y_events: &a11y_events,
                    now_seconds: self.boot_instant.elapsed().as_secs_f64(),
                    renderer,
                });
                if let Some(app) = out.appearance {
                    apply_macos_appearance(&mw.window, app);
                }
                if let Some(vis) = out.visible
                    && vis != mw.current_visible
                {
                    mw.current_visible = vis;
                    mw.window.set_visible(vis);
                    if vis {
                        mw.window.focus_window();
                        #[cfg(target_os = "macos")]
                        crate::window_macos::activate_macos_window(&mw.window);
                    }
                }
                if let Some(title) = out.title
                    && title != mw.current_title
                {
                    mw.window.set_title(&title);
                    mw.current_title = title;
                }
                if out.start_window_drag {
                    let _ = mw.window.drag_window();
                }
                if out.cursor != mw.current_cursor {
                    mw.current_cursor = out.cursor;
                    mw.window.set_cursor(map_cursor(out.cursor));
                }
                if out.ime_cursor_rect != mw.last_ime_rect {
                    mw.last_ime_rect = out.ime_cursor_rect;
                    if let Some(r) = out.ime_cursor_rect {
                        mw.window.set_ime_cursor_area(
                            LogicalPosition::new(f64::from(r.x), f64::from(r.y)),
                            LogicalSize::new(f64::from(r.width.max(2.0)), f64::from(r.height.max(14.0))),
                        );
                    }
                }
                mw.continuous_redraw = out.animate_continuously;
                mw.next_wakeup = out.next_wakeup_after.map(|d| Instant::now() + d);
                sync_window_a11y(&mw.window, &out.a11y_nodes, &mw.a11y_queue);
                let _ = renderer.render_to_surface(&mut mw.surface, sf, &out.scene);
            }
            other => {
                let Some(mw) = self.windows.get_mut(&window_id) else {
                    return;
                };
                let sf = mw.window.scale_factor() as f32;
                match other {
                    WindowEvent::CloseRequested => {
                        mw.pending_events.push(UiInputEvent::CloseRequested);
                        if mw.is_main && self.main_config.exit_on_close {
                            event_loop.exit();
                            return;
                        }
                        mw.current_visible = false;
                        mw.window.set_visible(false);
                    }
                    WindowEvent::Resized(phys) => {
                        if let Some(r) = self.renderer.as_ref() {
                            mw.surface.resize(r.device(), phys.width, phys.height);
                        }
                        mw.pending_events.push(UiInputEvent::Resized(Size::new(
                            phys.width as f32 / sf.max(1.0),
                            phys.height as f32 / sf.max(1.0),
                        )));
                    }
                    WindowEvent::Moved(_) => {
                        mw.window.request_redraw();
                        return;
                    }
                    WindowEvent::Focused(f) => mw.pending_events.push(UiInputEvent::Focused(f)),
                    WindowEvent::HoveredFile(_) => mw.pending_events.push(UiInputEvent::FileHovered(true)),
                    WindowEvent::HoveredFileCancelled => {
                        mw.pending_events.push(UiInputEvent::FileHovered(false))
                    }
                    WindowEvent::DroppedFile(path) => {
                        mw.pending_events.push(UiInputEvent::FileHovered(false));
                        mw.pending_events.push(UiInputEvent::FileDropped(path));
                    }
                    WindowEvent::CursorMoved { position, .. } => {
                        let pt = logical_pt(position, sf);
                        mw.pointer_pos = Some(pt);
                        mw.pending_events.push(UiInputEvent::PointerMoved(pt));
                    }
                    WindowEvent::MouseInput { state, button, .. } => {
                        let pos = mw.pointer_pos.unwrap_or(Point::ZERO);
                        if state == ElementState::Pressed {
                            let now = Instant::now();
                            let count = match mw.last_click {
                                Some((t, p, c))
                                    if now.duration_since(t).as_millis() <= 350
                                        && (pos.x - p.x).abs() <= 6.0
                                        && (pos.y - p.y).abs() <= 6.0 =>
                                {
                                    (c % 3) + 1
                                }
                                _ => 1,
                            };
                            mw.last_click = Some((now, pos, count));
                            mw.pending_events.push(UiInputEvent::PointerDown {
                                pos,
                                button,
                                click_count: count,
                            });
                        } else {
                            mw.pending_events.push(UiInputEvent::PointerUp { pos, button });
                        }
                    }
                    WindowEvent::MouseWheel { delta, phase, .. } => {
                        mw.pending_events.push(UiInputEvent::Wheel { delta, phase })
                    }
                    WindowEvent::Ime(Ime::Preedit(pre, _)) => {
                        mw.pending_events.push(UiInputEvent::ImePreedit(pre));
                    }
                    WindowEvent::Ime(Ime::Disabled) => {
                        mw.pending_events.push(UiInputEvent::ImePreedit(String::new()));
                    }
                    WindowEvent::Ime(Ime::Commit(committed)) => {
                        mw.pending_events.push(UiInputEvent::ImePreedit(String::new()));
                        let filtered: String = committed.chars().filter(|c| !c.is_control()).collect();
                        if !filtered.is_empty() {
                            mw.pending_events.push(UiInputEvent::Key {
                                key: EditKey::Text(filtered),
                                modifiers: self.modifiers,
                            });
                        }
                    }
                    WindowEvent::KeyboardInput { event, .. } if event.state == ElementState::Pressed => {
                        if let Some(key) = crate::text_nav::translate_winit_key(
                            &event.logical_key,
                            event.text.as_deref(),
                            self.modifiers,
                        ) {
                            mw.pending_events.push(UiInputEvent::Key {
                                key,
                                modifiers: self.modifiers,
                            });
                        }
                    }
                    _ => return,
                }
                mw.window.request_redraw();
            }
        }
    }

    fn about_to_wait(&mut self, event_loop: &ActiveEventLoop) {
        let main_win = self
            .windows
            .values()
            .find(|mw| mw.is_main)
            .map(|mw| mw.window.clone());
        let popup_dirty = main_win.as_ref().is_some_and(|w| self.delegate.on_after_frame(w));
        let external_dirty = popup_dirty || self.delegate.on_idle_poll();
        let now = Instant::now();
        let mut any_continuous = false;
        let mut earliest_wake: Option<Instant> = None;
        for mw in self.windows.values_mut() {
            let timer_due = mw.next_wakeup.is_some_and(|t| now >= t);
            if timer_due {
                mw.next_wakeup = None;
            }
            if mw.continuous_redraw || external_dirty || timer_due || !mw.pending_events.is_empty() {
                mw.window.request_redraw();
            }
            any_continuous |= mw.continuous_redraw;
            if let Some(t) = mw.next_wakeup {
                earliest_wake = Some(earliest_wake.map_or(t, |cur| cur.min(t)));
            }
        }
        event_loop.set_control_flow(if any_continuous {
            ControlFlow::Poll
        } else if let Some(deadline) = earliest_wake {
            ControlFlow::WaitUntil(deadline)
        } else {
            ControlFlow::Wait
        });
    }
}

fn build_window_attrs(cfg: &WindowConfig) -> WindowAttributes {
    let (init, min) = (cfg.initial_size, cfg.min_size);
    Window::default_attributes()
        .with_title(&cfg.title)
        .with_inner_size(LogicalSize::new(f64::from(init.width), f64::from(init.height)))
        .with_min_inner_size(LogicalSize::new(f64::from(min.width), f64::from(min.height)))
        .with_decorations(cfg.decorations)
        .with_resizable(cfg.resizable)
        .with_transparent(cfg.vibrant)
        .with_visible(cfg.initial_visible)
}

fn logical_pt(pos: PhysicalPosition<f64>, sf: f32) -> Point {
    let s = f64::from(sf.max(1.0));
    Point::new((pos.x / s) as f32, (pos.y / s) as f32)
}

fn map_cursor(c: CursorKind) -> CursorIcon {
    match c {
        CursorKind::Arrow => CursorIcon::Default,
        CursorKind::PointingHand => CursorIcon::Pointer,
        CursorKind::IBeam => CursorIcon::Text,
        CursorKind::ResizeColumn => CursorIcon::ColResize,
        CursorKind::Crosshair => CursorIcon::Crosshair,
    }
}

pub fn apply_macos_appearance(window: &Window, appearance: WindowAppearance) {
    #[cfg(target_os = "macos")]
    crate::window_macos::apply_macos_appearance(window, appearance);
    #[cfg(not(target_os = "macos"))]
    let _ = (window, appearance);
}

fn configure_macos_window_chrome(window: &Window, cfg: &WindowConfig) {
    #[cfg(target_os = "macos")]
    crate::window_macos::configure_macos_unified_window(window, cfg.fullsize_content_view, cfg.vibrant);
    #[cfg(not(target_os = "macos"))]
    let _ = (window, cfg);
}
