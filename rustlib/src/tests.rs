use super::*;
use std::fs;
use std::io::Write;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU32, Ordering};

static DIR_COUNTER: AtomicU32 = AtomicU32::new(0);

/// Helper: create a unique temp directory and return its path.
fn temp_dir(name: &str) -> PathBuf {
    let n = DIR_COUNTER.fetch_add(1, Ordering::SeqCst);
    let dir = std::env::temp_dir().join(format!("turbolog_test_{}_{}", name, n));
    if dir.exists() {
        let _ = fs::remove_dir_all(&dir);
    }
    fs::create_dir_all(&dir).unwrap();
    dir
}

/// Helper: create a file at `dir/filename` with given content.
fn touch_file(dir: &std::path::Path, filename: &str, content: &[u8]) {
    let path = dir.join(filename);
    let mut f = fs::File::create(&path).unwrap();
    f.write_all(content).unwrap();
    f.flush().unwrap();
}

/// Helper: read file content as bytes.
fn read_file(dir: &std::path::Path, filename: &str) -> Vec<u8> {
    fs::read(dir.join(filename)).unwrap_or_default()
}

// ========================================================================
// clear_logs_internal tests
// ========================================================================

#[test]
fn test_clear_logs_truncates_current() {
    let dir = temp_dir("truncate");
    touch_file(&dir, "turbolog.log", b"current log data");
    touch_file(&dir, "turbolog.log.2026-08-01", b"archived log data");

    let count = clear_logs_internal(&dir, true);

    assert_eq!(read_file(&dir, "turbolog.log").len(), 0);
    assert!(!dir.join("turbolog.log.2026-08-01").exists());
    assert_eq!(count, 2);

    let _ = fs::remove_dir_all(&dir);
}

#[test]
fn test_clear_logs_keeps_current_when_false() {
    let dir = temp_dir("keep");
    touch_file(&dir, "turbolog.log", b"precious data");
    touch_file(&dir, "turbolog.log.2026-08-01", b"old stuff");

    let count = clear_logs_internal(&dir, false);

    assert_eq!(read_file(&dir, "turbolog.log"), b"precious data");
    assert!(!dir.join("turbolog.log.2026-08-01").exists());
    assert_eq!(count, 1);

    let _ = fs::remove_dir_all(&dir);
}

#[test]
fn test_clear_logs_empty_dir() {
    let dir = temp_dir("empty");
    let count = clear_logs_internal(&dir, true);
    assert_eq!(count, 0);

    let _ = fs::remove_dir_all(&dir);
}

#[test]
fn test_clear_logs_ignores_other_files() {
    let dir = temp_dir("ignore");
    touch_file(&dir, "turbolog.log", b"log data");
    touch_file(&dir, "other.txt", b"keep me");
    touch_file(&dir, "turbolog.log.2026-08-01", b"archive");

    let count = clear_logs_internal(&dir, true);

    assert_eq!(read_file(&dir, "other.txt"), b"keep me");
    assert_eq!(count, 2);

    let _ = fs::remove_dir_all(&dir);
}

#[test]
fn test_clear_logs_nonexistent_dir() {
    let dir = PathBuf::from("/nonexistent_path_turbolog_test_xyz");
    let count = clear_logs_internal(&dir, true);
    assert_eq!(count, 0);
}

/// Regression test for Required #2: clear_logs_internal_locked must produce
/// the same observable result as clear_logs_internal when no writer lock is
/// supplied. This guards the truncation-coordination path used by the JNI
/// entry point against diverging from the standalone behavior.
#[test]
fn test_clear_logs_locked_without_writer_matches_unlocked() {
    let dir = temp_dir("locked_no_writer");

    touch_file(&dir, "turbolog.log", b"active contents");
    touch_file(&dir, "turbolog.log.2026-08-01", b"archive contents");
    touch_file(&dir, "unrelated.bin", b"keep me");

    let count = clear_logs_internal_locked(&dir, true, None);

    assert_eq!(count, 2, "should process active + one archived file");
    assert_eq!(
        read_file(&dir, "turbolog.log").len(),
        0,
        "active file must be truncated to 0 bytes"
    );
    assert!(
        !dir.join("turbolog.log.2026-08-01").exists(),
        "archived file must be deleted"
    );
    assert_eq!(
        read_file(&dir, "unrelated.bin"),
        b"keep me",
        "unrelated files must be untouched"
    );

    let _ = fs::remove_dir_all(&dir);
}

/// Regression test for Required #2: when clear_current is false, the active
/// file must be preserved even through the locked path.
#[test]
fn test_clear_logs_locked_keeps_current_when_false() {
    let dir = temp_dir("locked_keep");
    touch_file(&dir, "turbolog.log", b"precious active data");
    touch_file(&dir, "turbolog.log.2026-08-01", b"old archive");

    let count = clear_logs_internal_locked(&dir, false, None);

    assert_eq!(count, 1, "only the archived file should be processed");
    assert_eq!(
        read_file(&dir, "turbolog.log"),
        b"precious active data",
        "active file must be preserved when clear_current is false"
    );

    let _ = fs::remove_dir_all(&dir);
}

// ========================================================================
// write_log_event tests
// ========================================================================

/// Replaced the previous `assert_eq!(2, 2)` no-op test (review Optional #7)
/// with a test that verifies write_log_event does not panic for any level
/// and accepts arbitrary tag/msg strings. Behavior dispatch is validated
/// end-to-end by the Android instrumented tests on a real tracing pipeline.
#[test]
fn test_write_log_event_all_levels() {
    for level in [2, 3, 4, 5, 6] {
        write_log_event(level, "TestTag", "test message");
    }
    // Unknown levels must fall back to info rather than panicking.
    write_log_event(99, "TestTag", "fallback test");
    write_log_event(0, "", "");
    write_log_event(-1, "TagWith 特殊字符", "消息 with \n newlines");
}

// ========================================================================
// Constants test
// ========================================================================

#[test]
fn test_log_file_prefix_constant() {
    assert_eq!(LOG_FILE_PREFIX, "turbolog.log");
}
