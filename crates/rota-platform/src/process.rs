use serde::{Deserialize, Serialize};

/// A PID paired with its kernel birth timestamp so signals never hit a recycled PID.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct OwnedProcess {
    pub pid: i32,
    pub parent: u32,
    pub seconds: u64,
    pub microseconds: u64,
}

#[cfg(target_os = "macos")]
unsafe extern "C" {
    fn proc_pidinfo(
        pid: libc::c_int,
        flavor: libc::c_int,
        arg: u64,
        buffer: *mut libc::c_void,
        buffersize: libc::c_int,
    ) -> libc::c_int;

    fn proc_listchildpids(
        ppid: libc::pid_t,
        buffer: *mut libc::c_void,
        buffersize: libc::c_int,
    ) -> libc::c_int;
}

#[cfg(target_os = "macos")]
const PROC_PIDTBSDINFO_FLAVOR: libc::c_int = 3;

#[cfg(target_os = "macos")]
#[repr(C)]
#[derive(Clone, Copy)]
struct ProcBsdInfo {
    pbi_flags: u32,
    pbi_status: u32,
    pbi_xstatus: u32,
    pbi_pid: u32,
    pbi_ppid: u32,
    pbi_uid: libc::uid_t,
    pbi_gid: libc::gid_t,
    pbi_ruid: libc::uid_t,
    pbi_rgid: libc::gid_t,
    pbi_svuid: libc::uid_t,
    pbi_svgid: libc::gid_t,
    rfu_1: u32,
    pbi_comm: [libc::c_char; 16],
    pbi_name: [libc::c_char; 32],
    pbi_nfiles: u32,
    pbi_pgid: u32,
    pbi_pjobc: u32,
    e_tdev: u32,
    e_tpgid: u32,
    pbi_nice: i32,
    pbi_start_tvsec: u64,
    pbi_start_tvusec: u64,
}

impl OwnedProcess {
    pub fn capture(pid: i32) -> Option<Self> {
        if pid <= 0 {
            return None;
        }
        #[cfg(target_os = "macos")]
        {
            // SAFETY: ProcBsdInfo matches Darwin's `struct proc_bsdinfo` in `<sys/proc_info.h>`.
            unsafe {
                let mut info: ProcBsdInfo = std::mem::zeroed();
                let size = std::mem::size_of::<ProcBsdInfo>() as libc::c_int;
                let got = proc_pidinfo(
                    pid,
                    PROC_PIDTBSDINFO_FLAVOR,
                    0,
                    (&raw mut info).cast::<libc::c_void>(),
                    size,
                );
                if got <= 0 {
                    return None;
                }
                Some(Self {
                    pid,
                    parent: info.pbi_ppid,
                    seconds: info.pbi_start_tvsec,
                    microseconds: info.pbi_start_tvusec,
                })
            }
        }
        #[cfg(target_os = "linux")]
        {
            let stat = std::fs::read_to_string(format!("/proc/{pid}/stat")).ok()?;
            let close = stat.rfind(')')?;
            let fields: Vec<&str> = stat[close + 2..].split_whitespace().collect();
            let ppid: u32 = fields.get(1)?.parse().ok()?;
            let start_ticks: u64 = fields.get(19)?.parse().ok()?;
            Some(Self {
                pid,
                parent: ppid,
                seconds: start_ticks,
                microseconds: 0,
            })
        }
        #[cfg(not(any(target_os = "macos", target_os = "linux")))]
        {
            Some(Self {
                pid,
                parent: 0,
                seconds: 0,
                microseconds: 0,
            })
        }
    }

    pub fn exists(&self) -> bool {
        let Some(current) = Self::capture(self.pid) else {
            return false;
        };
        current.seconds == self.seconds && current.microseconds == self.microseconds
    }

    pub fn signal(&self, sig: i32) {
        if self.exists() {
            // SAFETY: Sending a POSIX signal to a verified owned PID.
            unsafe {
                let _ = libc::kill(self.pid, sig);
            }
        }
    }

    /// Captures descendants deepest-first before terminating their parent.
    pub fn descendants(&self) -> Vec<Self> {
        if !self.exists() {
            return Vec::new();
        }
        #[cfg(target_os = "macos")]
        {
            let mut pids = vec![0i32; 4096];
            let byte_len = (pids.len() * std::mem::size_of::<i32>()) as libc::c_int;
            // SAFETY: Buffer is valid writable memory of `byte_len` bytes.
            let bytes =
                unsafe { proc_listchildpids(self.pid, pids.as_mut_ptr().cast::<libc::c_void>(), byte_len) };
            if bytes <= 0 {
                return Vec::new();
            }
            let count = (bytes as usize) / std::mem::size_of::<i32>();
            let mut out = Vec::new();
            for &child_pid in &pids[..count.min(pids.len())] {
                if child_pid <= 0 {
                    continue;
                }
                if let Some(child) = Self::capture(child_pid)
                    && child.parent == self.pid as u32
                {
                    out.extend(child.descendants());
                    out.push(child);
                }
            }
            out
        }
        #[cfg(target_os = "linux")]
        {
            let mut out = Vec::new();
            let path = format!("/proc/{}/task/{}/children", self.pid, self.pid);
            if let Ok(content) = std::fs::read_to_string(path) {
                for token in content.split_whitespace() {
                    if let Ok(child_pid) = token.parse::<i32>()
                        && let Some(child) = Self::capture(child_pid)
                        && child.parent == self.pid as u32
                    {
                        out.extend(child.descendants());
                        out.push(child);
                    }
                }
            }
            out
        }
        #[cfg(not(any(target_os = "macos", target_os = "linux")))]
        {
            Vec::new()
        }
    }
}

/// Process group ID when `pid` is its own process-group leader and not Rota itself.
pub fn owned_process_group(pid: i32) -> Option<i32> {
    if pid <= 0 {
        return None;
    }
    // SAFETY: Standard POSIX process-group inspection.
    unsafe {
        let pgid = libc::getpgid(pid);
        let self_pgrp = libc::getpgrp();
        if pgid == pid && pid != self_pgrp {
            Some(pid)
        } else {
            None
        }
    }
}

pub fn signal_pid_or_group(pid: i32, group: Option<i32>, sig: i32) {
    let target = group.map_or(pid, |g| -g);
    // SAFETY: Standard POSIX kill to process or process group.
    unsafe {
        let _ = libc::kill(target, sig);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn current_process_is_captured_and_exists() {
        let pid = std::process::id() as i32;
        let me = OwnedProcess::capture(pid).expect("capture self");
        assert_eq!(me.pid, pid);
        assert!(me.exists());

        let mut forged = me;
        forged.seconds = forged.seconds.wrapping_add(100);
        assert!(!forged.exists());
    }
}
