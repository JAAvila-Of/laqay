//! Stage encoded image data in the destination folder and publish without replacement.

use std::{
    fs::{self, File, OpenOptions},
    io,
    os::windows::ffi::OsStrExt,
    path::{Path, PathBuf},
    sync::atomic::{AtomicU64, Ordering},
};
use windows::{
    Win32::Storage::FileSystem::{MOVEFILE_WRITE_THROUGH, MoveFileExW},
    core::PCWSTR,
};

static NEXT_TEMPORARY_ID: AtomicU64 = AtomicU64::new(0);

/// A validated local wall-clock timestamp supplied by the caller at paste time.
#[derive(Debug, Clone, Copy)]
pub struct ScreenshotTime {
    year: u16,
    month: u8,
    day: u8,
    hour: u8,
    minute: u8,
    second: u8,
}

impl ScreenshotTime {
    pub fn new(
        year: u16,
        month: u8,
        day: u8,
        hour: u8,
        minute: u8,
        second: u8,
    ) -> io::Result<Self> {
        let leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0);
        let days = match month {
            1 | 3 | 5 | 7 | 8 | 10 | 12 => 31,
            4 | 6 | 9 | 11 => 30,
            2 if leap => 29,
            2 => 28,
            _ => 0,
        };
        if !(1601..=9999).contains(&year)
            || day == 0
            || day > days
            || hour > 23
            || minute > 59
            || second > 59
        {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "Invalid screenshot timestamp",
            ));
        }
        Ok(Self {
            year,
            month,
            day,
            hour,
            minute,
            second,
        })
    }

    pub fn filename(self, collision: u32) -> String {
        let Self {
            year,
            month,
            day,
            hour,
            minute,
            second,
        } = self;
        let stem =
            format!("Screenshot_{year:04}{month:02}{day:02}_{hour:02}{minute:02}{second:02}");
        if collision == 0 {
            format!("{stem}.png")
        } else {
            format!("{stem}_{collision:03}.png")
        }
    }
}

struct PendingFile {
    path: Option<PathBuf>,
    file: Option<File>,
}

impl Drop for PendingFile {
    fn drop(&mut self) {
        self.file.take();
        if let Some(path) = self.path.take() {
            // Cleanup is best-effort after an I/O failure, panic, or disconnected share.
            // A stranded staging file retains its .tmp extension, never a .png name.
            let _ = fs::remove_file(path);
        }
    }
}

fn reserve_staging_file(directory: &Path) -> io::Result<PendingFile> {
    for _ in 0..1024 {
        let id = NEXT_TEMPORARY_ID
            .fetch_update(Ordering::Relaxed, Ordering::Relaxed, |id| id.checked_add(1))
            .map_err(|_| io::Error::other("Staging identifiers exhausted"))?;
        let path = directory.join(format!(".laqay-{}-{id}.tmp", std::process::id()));
        match OpenOptions::new().write(true).create_new(true).open(&path) {
            Ok(file) => {
                return Ok(PendingFile {
                    path: Some(path),
                    file: Some(file),
                });
            }
            Err(error) if error.kind() == io::ErrorKind::AlreadyExists => continue,
            Err(error) => return Err(error),
        }
    }
    Err(io::Error::new(
        io::ErrorKind::AlreadyExists,
        "Unable to reserve a staging file",
    ))
}

fn wide_path(path: &Path) -> io::Result<Vec<u16>> {
    let mut encoded: Vec<u16> = path.as_os_str().encode_wide().collect();
    if encoded.contains(&0) {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "A path contains a null character",
        ));
    }
    encoded.push(0);
    Ok(encoded)
}

/// Encode a complete PNG into a staging file and rename it to an unused final name.
/// The encoder must produce valid PNG bytes and must not retain the file handle.
/// Context authorization, PNG validation, and Shell notification belong to the caller.
/// Directory changes and disconnected shares can leave a .tmp file after failure;
/// no failed encoding is published with a PNG extension.
pub fn create_screenshot(
    directory: &Path,
    time: ScreenshotTime,
    encode: impl FnOnce(&mut File) -> io::Result<()>,
) -> io::Result<PathBuf> {
    if !directory.is_absolute() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "An absolute destination is required",
        ));
    }
    // Validate the path before creating any output.
    wide_path(directory)?;
    let mut pending = reserve_staging_file(directory)?;
    let file = pending
        .file
        .as_mut()
        .ok_or_else(|| io::Error::other("Missing staging handle"))?;
    encode(file)?;
    file.sync_all()?;
    pending.file.take();
    let source = wide_path(
        pending
            .path
            .as_deref()
            .ok_or_else(|| io::Error::other("Missing staging path"))?,
    )?;
    let mut collision = 0;
    loop {
        let destination = directory.join(time.filename(collision));
        let target = wide_path(&destination)?;
        // SAFETY: Both strings are NUL-terminated and live through the call.
        // Both paths are in the same supplied directory. REPLACE_EXISTING and
        // COPY_ALLOWED are deliberately absent: existing files cannot be replaced
        // and no cross-volume copy fallback is requested.
        let result = unsafe {
            MoveFileExW(
                PCWSTR(source.as_ptr()),
                PCWSTR(target.as_ptr()),
                MOVEFILE_WRITE_THROUGH,
            )
        };
        match result {
            Ok(()) => {
                pending.path.take();
                return Ok(destination);
            }
            Err(error) => {
                let hresult = error.code().0 as u32;
                let error = if hresult & 0xffff0000 == 0x80070000 {
                    io::Error::from_raw_os_error((hresult & 0xffff) as i32)
                } else {
                    io::Error::other(error.to_string())
                };
                if error.kind() != io::ErrorKind::AlreadyExists
                    && fs::symlink_metadata(&destination).is_err()
                {
                    return Err(error);
                }
                collision = collision.checked_add(1).ok_or_else(|| {
                    io::Error::new(io::ErrorKind::AlreadyExists, "Screenshot names exhausted")
                })?;
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    struct TestDirectory(PathBuf);
    impl TestDirectory {
        fn new() -> Self {
            let id = NEXT_TEMPORARY_ID.fetch_add(1, Ordering::Relaxed);
            let path =
                std::env::temp_dir().join(format!("laqay-writer-test-{}-{id}", std::process::id()));
            fs::create_dir(&path).unwrap();
            Self(path)
        }
    }
    impl Drop for TestDirectory {
        fn drop(&mut self) {
            for entry in fs::read_dir(&self.0).unwrap() {
                fs::remove_file(entry.unwrap().path()).unwrap();
            }
            fs::remove_dir(&self.0).unwrap();
        }
    }
    fn time() -> ScreenshotTime {
        ScreenshotTime::new(2026, 10, 29, 9, 5, 7).unwrap()
    }

    #[test]
    fn names_are_padded_and_collision_numbers_can_grow() {
        assert_eq!(time().filename(0), "Screenshot_20261029_090507.png");
        assert_eq!(time().filename(1), "Screenshot_20261029_090507_001.png");
        assert_eq!(time().filename(1000), "Screenshot_20261029_090507_1000.png");
    }

    #[test]
    fn validates_calendar_and_clock_values() {
        assert!(ScreenshotTime::new(2000, 2, 29, 0, 0, 0).is_ok());
        for (year, month, day, hour, minute, second) in [
            (1900, 2, 29, 0, 0, 0),
            (2026, 4, 31, 0, 0, 0),
            (2026, 0, 1, 0, 0, 0),
            (2026, 13, 1, 0, 0, 0),
            (2026, 1, 0, 0, 0, 0),
            (2026, 1, 1, 24, 0, 0),
            (2026, 1, 1, 0, 60, 0),
            (2026, 1, 1, 0, 0, 60),
        ] {
            assert!(ScreenshotTime::new(year, month, day, hour, minute, second).is_err());
        }
    }

    #[test]
    fn preserves_collisions_and_publishes_only_after_encoding() {
        let directory = TestDirectory::new();
        let original = directory.0.join(time().filename(0));
        fs::write(&original, b"original").unwrap();
        let output = create_screenshot(&directory.0, time(), |file| {
            assert!(!directory.0.join(time().filename(1)).exists());
            file.write_all(b"encoded image")
        })
        .unwrap();
        assert_eq!(output.file_name().unwrap(), time().filename(1).as_str());
        assert_eq!(fs::read(original).unwrap(), b"original");
        assert_eq!(fs::read(output).unwrap(), b"encoded image");
        assert_eq!(fs::read_dir(&directory.0).unwrap().count(), 2);
    }

    #[test]
    fn encoding_failure_removes_staging_data_without_a_png() {
        let directory = TestDirectory::new();
        let result = create_screenshot(&directory.0, time(), |file| {
            file.write_all(b"partial")?;
            Err(io::Error::other("encoder failed"))
        });
        assert!(result.is_err());
        assert_eq!(fs::read_dir(&directory.0).unwrap().count(), 0);
    }

    #[test]
    fn parallel_writers_never_replace_each_other() {
        let directory = TestDirectory::new();
        let paths = std::thread::scope(|scope| {
            let mut workers = Vec::new();
            for value in 0u8..8 {
                let folder = &directory.0;
                workers.push(scope.spawn(move || {
                    create_screenshot(folder, time(), |file| file.write_all(&[value])).unwrap()
                }));
            }
            workers
                .into_iter()
                .map(|worker| worker.join().unwrap())
                .collect::<Vec<_>>()
        });
        let mut values: Vec<_> = paths
            .iter()
            .map(|path| fs::read(path).unwrap()[0])
            .collect();
        values.sort();
        assert_eq!(values, (0u8..8).collect::<Vec<_>>());
        assert_eq!(fs::read_dir(&directory.0).unwrap().count(), 8);
    }

    #[test]
    fn relative_destinations_are_rejected_before_encoding() {
        let result =
            create_screenshot(Path::new("relative"), time(), |_| panic!("must not encode"));
        assert_eq!(result.unwrap_err().kind(), io::ErrorKind::InvalidInput);
    }
}
