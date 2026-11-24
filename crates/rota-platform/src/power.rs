use std::sync::{Arc, Mutex};

/// Monotonic awake and wall-including boot clocks, used to filter macOS dark wakes.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct SleepReading {
    /// Seconds since boot excluding sleep.
    pub awake: f64,
    /// Seconds since boot including sleep.
    pub total: f64,
}

impl SleepReading {
    pub fn now() -> Self {
        #[cfg(target_os = "macos")]
        {
            unsafe extern "C" {
                fn clock_gettime_nsec_np(clock_id: libc::clockid_t) -> u64;
            }
            // SAFETY: Darwin clock_gettime_nsec_np with valid clock IDs.
            unsafe {
                let awake = clock_gettime_nsec_np(libc::CLOCK_UPTIME_RAW) as f64 / 1e9;
                let total = clock_gettime_nsec_np(libc::CLOCK_MONOTONIC_RAW) as f64 / 1e9;
                Self { awake, total }
            }
        }
        #[cfg(target_os = "linux")]
        {
            unsafe {
                let mut up = libc::timespec {
                    tv_sec: 0,
                    tv_nsec: 0,
                };
                let mut boot = libc::timespec {
                    tv_sec: 0,
                    tv_nsec: 0,
                };
                let _ = libc::clock_gettime(libc::CLOCK_MONOTONIC, &raw mut up);
                let _ = libc::clock_gettime(libc::CLOCK_BOOTTIME, &raw mut boot);
                Self {
                    awake: up.tv_sec as f64 + up.tv_nsec as f64 / 1e9,
                    total: boot.tv_sec as f64 + boot.tv_nsec as f64 / 1e9,
                }
            }
        }
        #[cfg(not(any(target_os = "macos", target_os = "linux")))]
        {
            Self {
                awake: 0.0,
                total: 0.0,
            }
        }
    }

    pub fn slept(self) -> f64 {
        self.total - self.awake
    }
}

/// System uptime in seconds (excluding sleep on macOS).
pub fn system_uptime_seconds() -> f64 {
    SleepReading::now().awake
}

#[derive(Debug, Clone, Default)]
pub struct SleepState {
    announced: Option<SleepReading>,
}

impl SleepState {
    pub const ABORTED_AFTER: f64 = 120.0;
    pub const SLEPT_AT_LEAST: f64 = 1.0;

    pub fn new() -> Self {
        Self { announced: None }
    }

    pub fn will_sleep(&mut self, reading: SleepReading) {
        self.announced = Some(reading);
    }

    pub fn did_wake(&mut self) {
        self.announced = None;
    }

    pub fn is_asleep(&self, reading: SleepReading) -> bool {
        let Some(announced) = self.announced else {
            return false;
        };
        reading.slept() - announced.slept() >= Self::SLEPT_AT_LEAST
            || reading.awake - announced.awake < Self::ABORTED_AFTER
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PowerEvent {
    NetworkChanged(bool),
    WillSleep,
    DidWake,
    WillPowerOff,
}

#[cfg(target_os = "macos")]
mod macos_net {
    use super::*;
    use block2::RcBlock;
    use dispatch2::DispatchQueue;
    use std::ffi::c_void;

    type NwPathMonitor = *mut c_void;
    type NwPath = *mut c_void;

    const NW_PATH_STATUS_SATISFIED: i32 = 1;

    unsafe extern "C" {
        fn nw_path_monitor_create() -> NwPathMonitor;
        fn nw_path_monitor_set_queue(monitor: NwPathMonitor, queue: *const c_void);
        fn nw_path_monitor_set_update_handler(monitor: NwPathMonitor, handler: *const c_void);
        fn nw_path_monitor_start(monitor: NwPathMonitor);
        fn nw_path_monitor_cancel(monitor: NwPathMonitor);
        fn nw_path_get_status(path: NwPath) -> i32;
        fn nw_release(obj: *mut c_void);
    }

    pub struct NetworkWatch {
        monitor: NwPathMonitor,
        _block: RcBlock<dyn Fn(NwPath)>,
        _queue: objc2::rc::Retained<DispatchQueue>,
    }

    // SAFETY: NetworkWatch holds a retained dispatch queue and nw_path_monitor cancelled on drop.
    unsafe impl Send for NetworkWatch {}
    unsafe impl Sync for NetworkWatch {}

    impl NetworkWatch {
        pub fn start(callback: Arc<dyn Fn(bool) + Send + Sync>) -> Self {
            let last = Arc::new(Mutex::new(None::<bool>));
            let queue: objc2::rc::Retained<DispatchQueue> =
                DispatchQueue::new("com.wiltodelta.rota.network", None).into();
            let block = RcBlock::new(move |path: NwPath| {
                // SAFETY: `path` is provided by Network.framework for the duration of the callback.
                let status = unsafe { nw_path_get_status(path) };
                let satisfied = status == NW_PATH_STATUS_SATISFIED;
                let mut guard = last.lock().unwrap();
                if *guard != Some(satisfied) {
                    *guard = Some(satisfied);
                    drop(guard);
                    callback(satisfied);
                }
            });
            // SAFETY: Network.framework C API calls with valid queue and heap-allocated block.
            let monitor = unsafe {
                let m = nw_path_monitor_create();
                let queue_ptr = objc2::rc::Retained::as_ptr(&queue).cast::<c_void>();
                nw_path_monitor_set_queue(m, queue_ptr);
                let block_ptr = (&*block as *const block2::Block<dyn Fn(NwPath)>).cast::<c_void>();
                nw_path_monitor_set_update_handler(m, block_ptr);
                nw_path_monitor_start(m);
                m
            };
            Self {
                monitor,
                _block: block,
                _queue: queue,
            }
        }
    }

    impl Drop for NetworkWatch {
        fn drop(&mut self) {
            if !self.monitor.is_null() {
                // SAFETY: Monitor was created by `nw_path_monitor_create`.
                unsafe {
                    nw_path_monitor_cancel(self.monitor);
                    nw_release(self.monitor);
                }
            }
        }
    }
}

pub struct NetworkMonitorHandle {
    #[cfg(target_os = "macos")]
    _inner: macos_net::NetworkWatch,
}

impl NetworkMonitorHandle {
    pub fn start<F>(on_change: F) -> Self
    where
        F: Fn(bool) + Send + Sync + 'static,
    {
        #[cfg(target_os = "macos")]
        {
            Self {
                _inner: macos_net::NetworkWatch::start(Arc::new(on_change)),
            }
        }
        #[cfg(not(target_os = "macos"))]
        {
            on_change(true);
            Self {}
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sleep_state_handles_dark_wake_and_aborted_sleep() {
        let mut state = SleepState::new();
        let t0 = SleepReading {
            awake: 100.0,
            total: 100.0,
        };
        assert!(!state.is_asleep(t0));

        state.will_sleep(t0);
        // Immediately after announcement: still considered asleep until aborted window expires.
        assert!(state.is_asleep(SleepReading {
            awake: 110.0,
            total: 110.5
        }));
        // Aborted sleep: 125s awake, 0s slept -> no longer asleep.
        assert!(!state.is_asleep(SleepReading {
            awake: 225.0,
            total: 225.2
        }));
        // Real sleep + dark wake: 200s awake, 500s total (300s slept) -> still asleep until did_wake!
        assert!(state.is_asleep(SleepReading {
            awake: 300.0,
            total: 600.0
        }));

        state.did_wake();
        assert!(!state.is_asleep(SleepReading {
            awake: 300.0,
            total: 600.0
        }));
    }
}
