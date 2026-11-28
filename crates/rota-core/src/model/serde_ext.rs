use jiff::Timestamp;
use jiff::tz::TimeZone;
use serde::{Deserialize, Deserializer, Serialize, Serializer};
use serde_json::{Map, Value};
use uuid::Uuid;

/// Formats a `Timestamp` as UTC ISO 8601 (`YYYY-MM-DDTHH:MM:SSZ` when whole seconds,
/// or millisecond precision `.SSSZ` when subsecond is non-zero).
pub fn format_iso_timestamp(ts: Timestamp) -> String {
    let z = ts.to_zoned(TimeZone::UTC);
    let sub_ns = ts.subsec_nanosecond();
    if sub_ns == 0 {
        format!(
            "{:04}-{:02}-{:02}T{:02}:{:02}:{:02}Z",
            z.year(),
            z.month(),
            z.day(),
            z.hour(),
            z.minute(),
            z.second()
        )
    } else {
        let ms = sub_ns.unsigned_abs() / 1_000_000;
        format!(
            "{:04}-{:02}-{:02}T{:02}:{:02}:{:02}.{:03}Z",
            z.year(),
            z.month(),
            z.day(),
            z.hour(),
            z.minute(),
            z.second(),
            ms
        )
    }
}

/// Parses an ISO 8601 / RFC 3339 timestamp with an explicit timezone (`Z` or numeric offset).
/// Rejects zone-less strings such as `"2026-11-15T10:00:00"`.
pub fn parse_iso_timestamp(text: &str) -> Option<Timestamp> {
    let trimmed = text.trim();
    if !trimmed.contains('T') && !trimmed.contains('t') {
        return None;
    }
    let after_t = trimmed.split_once(['T', 't'])?.1;
    let has_zone = after_t.ends_with(['Z', 'z'])
        || after_t.contains('+')
        || after_t.rfind('-').is_some_and(|idx| idx > 0);
    if !has_zone {
        return None;
    }
    trimmed.parse::<Timestamp>().ok()
}

pub mod iso_timestamp {
    use super::*;

    pub fn serialize<S: Serializer>(ts: &Timestamp, serializer: S) -> Result<S::Ok, S::Error> {
        serializer.serialize_str(&format_iso_timestamp(*ts))
    }

    pub fn deserialize<'de, D: Deserializer<'de>>(deserializer: D) -> Result<Timestamp, D::Error> {
        let raw = String::deserialize(deserializer)?;
        parse_iso_timestamp(&raw)
            .ok_or_else(|| serde::de::Error::custom(format!("Invalid ISO 8601 timestamp: {raw}")))
    }
}

pub mod opt_iso_timestamp {
    use super::*;

    pub fn serialize<S: Serializer>(ts: &Option<Timestamp>, serializer: S) -> Result<S::Ok, S::Error> {
        match ts {
            Some(val) => serializer.serialize_some(&format_iso_timestamp(*val)),
            None => serializer.serialize_none(),
        }
    }

    pub fn deserialize<'de, D: Deserializer<'de>>(deserializer: D) -> Result<Option<Timestamp>, D::Error> {
        let opt = Option::<String>::deserialize(deserializer)?;
        match opt {
            Some(raw) => parse_iso_timestamp(&raw)
                .map(Some)
                .ok_or_else(|| serde::de::Error::custom(format!("Invalid ISO 8601 timestamp: {raw}"))),
            None => Ok(None),
        }
    }
}

/// Formats `Uuid` in Swift Foundation uppercase style (`"6F1C2A3B-..."`).
pub fn uppercase_uuid(id: Uuid) -> String {
    id.hyphenated().to_string().to_ascii_uppercase()
}

pub mod swift_uuid {
    use super::*;

    pub fn serialize<S: Serializer>(id: &Uuid, serializer: S) -> Result<S::Ok, S::Error> {
        serializer.serialize_str(&uppercase_uuid(*id))
    }

    pub fn deserialize<'de, D: Deserializer<'de>>(deserializer: D) -> Result<Uuid, D::Error> {
        let raw = String::deserialize(deserializer)?;
        Uuid::parse_str(&raw).map_err(serde::de::Error::custom)
    }
}

pub mod opt_swift_uuid {
    use super::*;

    pub fn serialize<S: Serializer>(id: &Option<Uuid>, serializer: S) -> Result<S::Ok, S::Error> {
        match id {
            Some(val) => serializer.serialize_some(&uppercase_uuid(*val)),
            None => serializer.serialize_none(),
        }
    }

    pub fn deserialize<'de, D: Deserializer<'de>>(deserializer: D) -> Result<Option<Uuid>, D::Error> {
        let opt = Option::<String>::deserialize(deserializer)?;
        match opt {
            Some(raw) => Uuid::parse_str(&raw).map(Some).map_err(serde::de::Error::custom),
            None => Ok(None),
        }
    }
}

/// Recursively sorts JSON object keys lexicographically so output matches Foundation `.sortedKeys`.
pub fn sort_json_value(value: Value) -> Value {
    match value {
        Value::Object(map) => {
            let mut entries: Vec<(String, Value)> =
                map.into_iter().map(|(k, v)| (k, sort_json_value(v))).collect();
            entries.sort_by(|a, b| a.0.cmp(&b.0));
            let mut sorted = Map::with_capacity(entries.len());
            for (k, v) in entries {
                sorted.insert(k, v);
            }
            Value::Object(sorted)
        }
        Value::Array(arr) => Value::Array(arr.into_iter().map(sort_json_value).collect()),
        other => other,
    }
}

pub fn to_sorted_pretty_vec<T: Serialize>(value: &T) -> Result<Vec<u8>, serde_json::Error> {
    let val = sort_json_value(serde_json::to_value(value)?);
    serde_json::to_vec_pretty(&val)
}

pub fn to_sorted_pretty_string<T: Serialize>(value: &T) -> Result<String, serde_json::Error> {
    let val = sort_json_value(serde_json::to_value(value)?);
    serde_json::to_string_pretty(&val)
}

pub fn to_sorted_compact_string<T: Serialize>(value: &T) -> Result<String, serde_json::Error> {
    let val = sort_json_value(serde_json::to_value(value)?);
    serde_json::to_string(&val)
}
