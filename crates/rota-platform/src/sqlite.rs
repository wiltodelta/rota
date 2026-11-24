use std::ffi::{CStr, CString, c_char, c_int, c_void};
use std::path::Path;
use std::ptr;

const SQLITE_OK: c_int = 0;
const SQLITE_ROW: c_int = 100;
const SQLITE_DONE: c_int = 101;
const SQLITE_OPEN_READONLY: c_int = 0x0000_0001;
const SQLITE_OPEN_NOMUTEX: c_int = 0x0000_8000;
const SQLITE_NULL: c_int = 5;

#[cfg(any(target_os = "macos", target_os = "linux"))]
unsafe extern "C" {
    fn sqlite3_open_v2(
        filename: *const c_char,
        pp_db: *mut *mut c_void,
        flags: c_int,
        z_vfs: *const c_char,
    ) -> c_int;
    fn sqlite3_close_v2(db: *mut c_void) -> c_int;
    fn sqlite3_errmsg(db: *mut c_void) -> *const c_char;
    fn sqlite3_prepare_v2(
        db: *mut c_void,
        z_sql: *const c_char,
        n_byte: c_int,
        pp_stmt: *mut *mut c_void,
        pz_tail: *mut *const c_char,
    ) -> c_int;
    fn sqlite3_step(stmt: *mut c_void) -> c_int;
    fn sqlite3_finalize(stmt: *mut c_void) -> c_int;
    fn sqlite3_column_count(stmt: *mut c_void) -> c_int;
    fn sqlite3_column_type(stmt: *mut c_void, i_col: c_int) -> c_int;
    fn sqlite3_column_text(stmt: *mut c_void, i_col: c_int) -> *const u8;
    fn sqlite3_column_int64(stmt: *mut c_void, i_col: c_int) -> i64;
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SqlValue {
    Null,
    Integer(i64),
    Text(String),
}

impl SqlValue {
    pub fn as_str(&self) -> Option<&str> {
        match self {
            Self::Text(s) => Some(s.as_str()),
            _ => None,
        }
    }

    pub fn as_i64(&self) -> Option<i64> {
        match self {
            Self::Integer(v) => Some(*v),
            Self::Text(s) => s.parse().ok(),
            Self::Null => None,
        }
    }
}

/// Read-only connection to a system SQLite database (`mode=ro`, never creates or mutates).
pub struct ReadOnlySqlite {
    #[cfg(any(target_os = "macos", target_os = "linux"))]
    db: *mut c_void,
}

impl ReadOnlySqlite {
    pub fn open(path: &Path) -> Result<Self, String> {
        #[cfg(any(target_os = "macos", target_os = "linux"))]
        {
            let uri = format!("file:{}?mode=ro", path.display());
            let c_path = CString::new(path.to_string_lossy().as_bytes())
                .map_err(|_| "Invalid database path".to_string())?;
            let _ = uri;
            let mut db: *mut c_void = ptr::null_mut();
            // SAFETY: `c_path` is a valid CString and `SQLITE_OPEN_READONLY` prevents file creation or writes.
            let rc = unsafe {
                sqlite3_open_v2(
                    c_path.as_ptr(),
                    &raw mut db,
                    SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX,
                    ptr::null(),
                )
            };
            if rc != SQLITE_OK || db.is_null() {
                let msg = if db.is_null() {
                    "Could not open SQLite database.".to_string()
                } else {
                    // SAFETY: `db` is non-null from `sqlite3_open_v2`.
                    let err = unsafe { CStr::from_ptr(sqlite3_errmsg(db)).to_string_lossy().into_owned() };
                    unsafe {
                        let _ = sqlite3_close_v2(db);
                    }
                    err
                };
                return Err(msg);
            }
            Ok(Self { db })
        }
        #[cfg(not(any(target_os = "macos", target_os = "linux")))]
        {
            let _ = path;
            Err("SQLite reader is not supported on this target.".to_string())
        }
    }

    pub fn query(&self, sql: &str) -> Result<Vec<Vec<SqlValue>>, String> {
        #[cfg(any(target_os = "macos", target_os = "linux"))]
        {
            let c_sql = CString::new(sql).map_err(|_| "Invalid SQL".to_string())?;
            let mut stmt: *mut c_void = ptr::null_mut();
            // SAFETY: `self.db` is an open read-only connection.
            let rc =
                unsafe { sqlite3_prepare_v2(self.db, c_sql.as_ptr(), -1, &raw mut stmt, ptr::null_mut()) };
            if rc != SQLITE_OK || stmt.is_null() {
                let err = unsafe {
                    CStr::from_ptr(sqlite3_errmsg(self.db))
                        .to_string_lossy()
                        .into_owned()
                };
                return Err(err);
            }
            let mut rows = Vec::new();
            loop {
                let step = unsafe { sqlite3_step(stmt) };
                if step == SQLITE_ROW {
                    let cols = unsafe { sqlite3_column_count(stmt) };
                    let mut row = Vec::with_capacity(cols.max(0) as usize);
                    for col in 0..cols {
                        let kind = unsafe { sqlite3_column_type(stmt, col) };
                        if kind == SQLITE_NULL {
                            row.push(SqlValue::Null);
                        } else if kind == 1 {
                            let val = unsafe { sqlite3_column_int64(stmt, col) };
                            row.push(SqlValue::Integer(val));
                        } else {
                            let ptr = unsafe { sqlite3_column_text(stmt, col) };
                            if ptr.is_null() {
                                row.push(SqlValue::Null);
                            } else {
                                let text = unsafe {
                                    CStr::from_ptr(ptr.cast::<c_char>())
                                        .to_string_lossy()
                                        .into_owned()
                                };
                                row.push(SqlValue::Text(text));
                            }
                        }
                    }
                    rows.push(row);
                } else if step == SQLITE_DONE {
                    break;
                } else {
                    let err = unsafe {
                        CStr::from_ptr(sqlite3_errmsg(self.db))
                            .to_string_lossy()
                            .into_owned()
                    };
                    unsafe {
                        let _ = sqlite3_finalize(stmt);
                    }
                    return Err(err);
                }
            }
            unsafe {
                let _ = sqlite3_finalize(stmt);
            }
            Ok(rows)
        }
        #[cfg(not(any(target_os = "macos", target_os = "linux")))]
        {
            let _ = sql;
            Err("Unsupported target".to_string())
        }
    }
}

#[cfg(any(target_os = "macos", target_os = "linux"))]
impl Drop for ReadOnlySqlite {
    fn drop(&mut self) {
        if !self.db.is_null() {
            // SAFETY: `self.db` was opened by `sqlite3_open_v2` and is closed once.
            unsafe {
                let _ = sqlite3_close_v2(self.db);
            }
        }
    }
}
