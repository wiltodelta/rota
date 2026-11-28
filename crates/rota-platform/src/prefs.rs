use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};

/// Cross-platform key-value preference store, backed by `NSUserDefaults` on macOS
/// (preserving existing Rota plist keys) or an isolated JSON/memory store in tests.
pub trait PreferencesStore: Send + Sync {
    fn get_bool(&self, key: &str) -> Option<bool>;
    fn set_bool(&self, key: &str, value: bool);
    fn get_f64(&self, key: &str) -> Option<f64>;
    fn set_f64(&self, key: &str, value: f64);
    fn get_string(&self, key: &str) -> Option<String>;
    fn set_string(&self, key: &str, value: Option<&str>);
    fn get_string_list(&self, key: &str) -> Option<Vec<String>>;
    fn set_string_list(&self, key: &str, values: &[String]);
    fn get_string_map(&self, key: &str) -> HashMap<String, String>;
    fn set_string_map(&self, key: &str, values: &HashMap<String, String>);
    fn get_bytes(&self, key: &str) -> Option<Vec<u8>>;
    fn set_bytes(&self, key: &str, bytes: &[u8]);
}

#[derive(Default)]
pub struct MemoryPreferences {
    values: Mutex<HashMap<String, serde_json::Value>>,
    backing_file: Option<PathBuf>,
}

impl MemoryPreferences {
    pub fn new() -> Arc<Self> {
        Arc::new(Self::default())
    }

    pub fn backed_by(path: PathBuf) -> Arc<Self> {
        let initial = std::fs::read(&path)
            .ok()
            .and_then(|bytes| serde_json::from_slice::<HashMap<String, serde_json::Value>>(&bytes).ok())
            .unwrap_or_default();
        Arc::new(Self {
            values: Mutex::new(initial),
            backing_file: Some(path),
        })
    }

    fn flush(&self, map: &HashMap<String, serde_json::Value>) {
        if let Some(path) = &self.backing_file {
            if let Some(parent) = path.parent() {
                let _ = std::fs::create_dir_all(parent);
            }
            if let Ok(bytes) = serde_json::to_vec_pretty(map) {
                let _ = std::fs::write(path, bytes);
            }
        }
    }
}

impl PreferencesStore for MemoryPreferences {
    fn get_bool(&self, key: &str) -> Option<bool> {
        self.values.lock().unwrap().get(key).and_then(|v| v.as_bool())
    }

    fn set_bool(&self, key: &str, value: bool) {
        let mut map = self.values.lock().unwrap();
        map.insert(key.to_string(), serde_json::Value::Bool(value));
        self.flush(&map);
    }

    fn get_f64(&self, key: &str) -> Option<f64> {
        self.values.lock().unwrap().get(key).and_then(|v| v.as_f64())
    }

    fn set_f64(&self, key: &str, value: f64) {
        let mut map = self.values.lock().unwrap();
        if let Some(num) = serde_json::Number::from_f64(value) {
            map.insert(key.to_string(), serde_json::Value::Number(num));
            self.flush(&map);
        }
    }

    fn get_string(&self, key: &str) -> Option<String> {
        self.values
            .lock()
            .unwrap()
            .get(key)
            .and_then(|v| v.as_str().map(ToOwned::to_owned))
    }

    fn set_string(&self, key: &str, value: Option<&str>) {
        let mut map = self.values.lock().unwrap();
        if let Some(text) = value {
            map.insert(key.to_string(), serde_json::Value::String(text.to_string()));
        } else {
            map.remove(key);
        }
        self.flush(&map);
    }

    fn get_string_list(&self, key: &str) -> Option<Vec<String>> {
        let map = self.values.lock().unwrap();
        let arr = map.get(key)?.as_array()?;
        Some(
            arr.iter()
                .filter_map(|v| v.as_str().map(ToOwned::to_owned))
                .collect(),
        )
    }

    fn set_string_list(&self, key: &str, values: &[String]) {
        let mut map = self.values.lock().unwrap();
        map.insert(
            key.to_string(),
            serde_json::Value::Array(
                values
                    .iter()
                    .map(|s| serde_json::Value::String(s.clone()))
                    .collect(),
            ),
        );
        self.flush(&map);
    }

    fn get_string_map(&self, key: &str) -> HashMap<String, String> {
        let map = self.values.lock().unwrap();
        let Some(obj) = map.get(key).and_then(|v| v.as_object()) else {
            return HashMap::new();
        };
        obj.iter()
            .filter_map(|(k, v)| v.as_str().map(|s| (k.clone(), s.to_string())))
            .collect()
    }

    fn set_string_map(&self, key: &str, values: &HashMap<String, String>) {
        let mut map = self.values.lock().unwrap();
        let obj = values
            .iter()
            .map(|(k, v)| (k.clone(), serde_json::Value::String(v.clone())))
            .collect();
        map.insert(key.to_string(), serde_json::Value::Object(obj));
        self.flush(&map);
    }

    fn get_bytes(&self, key: &str) -> Option<Vec<u8>> {
        let map = self.values.lock().unwrap();
        let arr = map.get(key)?.as_array()?;
        arr.iter()
            .map(|v| v.as_u64().and_then(|n| u8::try_from(n).ok()))
            .collect()
    }

    fn set_bytes(&self, key: &str, bytes: &[u8]) {
        let mut map = self.values.lock().unwrap();
        map.insert(
            key.to_string(),
            serde_json::Value::Array(bytes.iter().map(|&b| serde_json::Value::from(b)).collect()),
        );
        self.flush(&map);
    }
}

#[cfg(target_os = "macos")]
pub struct MacUserDefaults;

#[cfg(target_os = "macos")]
impl PreferencesStore for MacUserDefaults {
    fn get_bool(&self, key: &str) -> Option<bool> {
        use objc2_foundation::{NSString, NSUserDefaults};
        let defaults = NSUserDefaults::standardUserDefaults();
        let ns_key = NSString::from_str(key);
        let obj = defaults.objectForKey(&ns_key)?;
        let _ = obj;
        Some(defaults.boolForKey(&ns_key))
    }

    fn set_bool(&self, key: &str, value: bool) {
        use objc2_foundation::{NSString, NSUserDefaults};
        let defaults = NSUserDefaults::standardUserDefaults();
        defaults.setBool_forKey(value, &NSString::from_str(key));
    }

    fn get_f64(&self, key: &str) -> Option<f64> {
        use objc2_foundation::{NSString, NSUserDefaults};
        let defaults = NSUserDefaults::standardUserDefaults();
        let ns_key = NSString::from_str(key);
        defaults.objectForKey(&ns_key)?;
        Some(defaults.doubleForKey(&ns_key))
    }

    fn set_f64(&self, key: &str, value: f64) {
        use objc2_foundation::{NSString, NSUserDefaults};
        let defaults = NSUserDefaults::standardUserDefaults();
        defaults.setDouble_forKey(value, &NSString::from_str(key));
    }

    fn get_string(&self, key: &str) -> Option<String> {
        use objc2_foundation::{NSString, NSUserDefaults};
        let defaults = NSUserDefaults::standardUserDefaults();
        defaults
            .stringForKey(&NSString::from_str(key))
            .map(|s| s.to_string())
    }

    fn set_string(&self, key: &str, value: Option<&str>) {
        use objc2_foundation::{NSString, NSUserDefaults};
        let defaults = NSUserDefaults::standardUserDefaults();
        let ns_key = NSString::from_str(key);
        if let Some(text) = value {
            let ns_val = NSString::from_str(text);
            unsafe { defaults.setObject_forKey(Some(&ns_val), &ns_key) };
        } else {
            defaults.removeObjectForKey(&ns_key);
        }
    }

    fn get_string_list(&self, key: &str) -> Option<Vec<String>> {
        use objc2_foundation::{NSString, NSUserDefaults};
        let defaults = NSUserDefaults::standardUserDefaults();
        let arr = defaults.stringArrayForKey(&NSString::from_str(key))?;
        let mut out = Vec::with_capacity(arr.count());
        for idx in 0..arr.count() {
            out.push(arr.objectAtIndex(idx).to_string());
        }
        Some(out)
    }

    fn set_string_list(&self, key: &str, values: &[String]) {
        use objc2_foundation::{NSArray, NSString, NSUserDefaults};
        let defaults = NSUserDefaults::standardUserDefaults();
        let items: Vec<_> = values.iter().map(|s| NSString::from_str(s)).collect();
        let refs: Vec<&NSString> = items.iter().map(|s| s.as_ref()).collect();
        let arr = NSArray::from_slice(&refs);
        unsafe { defaults.setObject_forKey(Some(&arr), &NSString::from_str(key)) };
    }

    fn get_string_map(&self, key: &str) -> HashMap<String, String> {
        use objc2::rc::Retained;
        use objc2_foundation::{NSString, NSUserDefaults};
        let defaults = NSUserDefaults::standardUserDefaults();
        let Some(dict) = defaults.dictionaryForKey(&NSString::from_str(key)) else {
            return HashMap::new();
        };
        let keys = dict.allKeys();
        let mut out = HashMap::new();
        for idx in 0..keys.count() {
            let k = keys.objectAtIndex(idx);
            if let Some(v) = dict.objectForKey(&k)
                && let Ok(v_str) = Retained::downcast::<NSString>(v)
            {
                out.insert(k.to_string(), v_str.to_string());
            }
        }
        out
    }

    fn set_string_map(&self, key: &str, values: &HashMap<String, String>) {
        use objc2::runtime::AnyObject;
        use objc2_foundation::{NSDictionary, NSString, NSUserDefaults};
        let defaults = NSUserDefaults::standardUserDefaults();
        let ks: Vec<_> = values.keys().map(|k| NSString::from_str(k)).collect();
        let vs: Vec<_> = values.values().map(|v| NSString::from_str(v)).collect();
        let k_refs: Vec<&NSString> = ks.iter().map(|s| s.as_ref()).collect();
        let v_refs: Vec<&AnyObject> = vs.iter().map(|s| s.as_ref() as &AnyObject).collect();
        let dict = NSDictionary::from_slices(&k_refs, &v_refs);
        unsafe { defaults.setObject_forKey(Some(&dict), &NSString::from_str(key)) };
    }

    fn get_bytes(&self, key: &str) -> Option<Vec<u8>> {
        use objc2_foundation::{NSString, NSUserDefaults};
        let defaults = NSUserDefaults::standardUserDefaults();
        let data = defaults.dataForKey(&NSString::from_str(key))?;
        Some(data.to_vec())
    }

    fn set_bytes(&self, key: &str, bytes: &[u8]) {
        use objc2_foundation::{NSData, NSString, NSUserDefaults};
        let defaults = NSUserDefaults::standardUserDefaults();
        let data = NSData::with_bytes(bytes);
        unsafe { defaults.setObject_forKey(Some(&data), &NSString::from_str(key)) };
    }
}

pub fn standard_preferences() -> Arc<dyn PreferencesStore> {
    if let Ok(dir) = std::env::var("ROTA_DATA_DIR")
        && !dir.is_empty()
        && crate::desktop::app_bundle_identifier().is_none()
    {
        return MemoryPreferences::backed_by(PathBuf::from(dir).join("preferences.json"));
    }
    #[cfg(target_os = "macos")]
    {
        if crate::desktop::app_bundle_identifier().is_some() {
            return Arc::new(MacUserDefaults);
        }
    }
    let fallback = crate::desktop::home_dir().join(".config/rota/preferences.json");
    MemoryPreferences::backed_by(fallback)
}
