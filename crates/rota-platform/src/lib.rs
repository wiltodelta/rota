//! Host platform abstractions for Rota (macOS first, portable across Unix/Windows).

pub mod desktop;
pub mod log;
pub mod notifications;
pub mod power;
pub mod prefs;
pub mod process;
pub mod sqlite;
pub mod system_info;
pub mod updater;

pub use desktop::{
    KnownTerminal, abbreviate_tilde, app_bundle_identifier, bundle_short_version, bundled_fonts_directory,
    bundled_helper_path, clipboard_get, clipboard_set, current_username, enclosing_app_bundle, expand_tilde,
    home_dir, installed_terminals, launch_rota_background, open_terminal_script, open_url_or_path,
    pick_directory, pick_files, register_bundled_fonts,
};
pub use log::{LogLevel, Logger};
pub use notifications::{NotificationPayload, NotificationUserEvent, SystemNotifier};
pub use power::{NetworkMonitorHandle, PowerEvent, SleepReading, SleepState, system_uptime_seconds};
pub use prefs::{MemoryPreferences, PreferencesStore, standard_preferences};
pub use process::{OwnedProcess, owned_process_group, signal_pid_or_group};
pub use sqlite::{ReadOnlySqlite, SqlValue};
pub use system_info::{
    ComputerUseAccess, ImageInspection, ProcessResourceReading, inspect_image_bytes, launch_at_login_enabled,
    probe_http_reachable, set_launch_at_login,
};
pub use updater::SystemUpdater;
