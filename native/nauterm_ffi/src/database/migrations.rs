use super::*;

/// Applies migrations beginning with the new Korvect schema baseline.
///
/// Schema version 1 is the first supported version. When version 2 is added,
/// its v1-to-v2 migration belongs here; schemas from the previous application
/// identity are intentionally unsupported.
pub(super) fn migrate_schema(_connection: &mut Connection, version: i32) -> rusqlite::Result<()> {
    match version {
        SCHEMA_VERSION => Ok(()),
        _ => Err(rusqlite::Error::InvalidParameterName(format!(
            "database schema version {version} is unsupported; expected {SCHEMA_VERSION}"
        ))),
    }
}
