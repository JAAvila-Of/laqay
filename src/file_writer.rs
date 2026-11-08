//! Stage encoded image data in the destination folder and publish without replacement.

use std::{
    collections::VecDeque,
    fs::{self, File, OpenOptions},
    io,
    os::windows::{
        ffi::OsStrExt,
        fs::{MetadataExt, OpenOptionsExt},
        io::AsRawHandle,
    },
    path::{Path, PathBuf},
    sync::{
        Mutex,
        atomic::{AtomicU64, Ordering},
    },
};
use windows::Win32::{
    Foundation::{FILETIME, HANDLE},
    Storage::FileSystem::{
        DELETE, FILE_ATTRIBUTE_REPARSE_POINT, FILE_DISPOSITION_INFO, FILE_FLAG_BACKUP_SEMANTICS,
        FILE_FLAG_OPEN_REPARSE_POINT, FILE_GENERIC_READ, FILE_GENERIC_WRITE, FILE_ID_INFO,
        FILE_READ_ATTRIBUTES, FILE_READ_DATA, FILE_RENAME_INFO, FILE_SHARE_READ, FILE_SHARE_WRITE,
        FileDispositionInfo, FileIdInfo, FileRenameInfo, GetFileInformationByHandleEx,
        SetFileInformationByHandle, SetFileTime,
    },
};

static NEXT_TEMPORARY_ID: AtomicU64 = AtomicU64::new(0);
const MAX_PENDING_CLEANUPS: usize = 32;
const MAX_CLEANUPS_PER_PASTE: usize = 4;
static PENDING_CLEANUPS: Mutex<VecDeque<OwnedStaging>> = Mutex::new(VecDeque::new());

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct FileIdentity {
    volume: u64,
    id: [u8; 16],
    created: u64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct StagingSnapshot {
    identity: FileIdentity,
    length: u64,
    written: u64,
}

struct OwnedStaging {
    path: PathBuf,
    snapshot: StagingSnapshot,
}

/// Only the writer can construct this proof for its completed staging file.
pub(crate) struct StagingContext<'a> {
    path: &'a Path,
    snapshot: Option<StagingSnapshot>,
    file: &'a File,
}

pub(crate) struct StagingLease {
    _file: File,
    path: PathBuf,
    snapshot: StagingSnapshot,
}

impl StagingContext<'_> {
    pub(crate) fn pin(&self) -> io::Result<StagingLease> {
        let expected = self
            .snapshot
            .ok_or_else(|| io::Error::other("Unknown staging identity"))?;
        // Duplicate the original exclusive writer instead of reopening a name.
        // The writer remains open through publication, with no write/delete
        // sharing, so there is no unlocked hand-off between the two handles.
        let file = self.file.try_clone()?;
        if staging_snapshot(&file)? != expected {
            return Err(io::Error::other("Staging identity or metadata changed"));
        }
        // This duplicate keeps the same file object alive during observation.
        Ok(StagingLease {
            _file: file,
            path: self.path.canonicalize()?,
            snapshot: expected,
        })
    }
}

/// Keep every component of the resolved destination stable until cleanup or
/// publication finishes. Reject reparse components rather than following a
/// concurrently replaced junction while acquiring the chain from root to leaf.
struct DirectoryLease {
    path: PathBuf,
    _components: Vec<File>,
}

impl DirectoryLease {
    fn pin(directory: &Path) -> io::Result<Self> {
        // Normalize lexically first, without following a junction that may
        // have replaced the already-approved path. Resolve only after every
        // original component is open and verified as a non-reparse directory.
        let path = std::path::absolute(directory)?;
        let mut components = Vec::new();
        for component in path.ancestors().collect::<Vec<_>>().into_iter().rev() {
            let file = OpenOptions::new()
                .access_mode(FILE_READ_DATA.0 | FILE_READ_ATTRIBUTES.0)
                .share_mode(FILE_SHARE_READ.0 | FILE_SHARE_WRITE.0)
                .custom_flags(FILE_FLAG_BACKUP_SEMANTICS.0 | FILE_FLAG_OPEN_REPARSE_POINT.0)
                .open(component)?;
            let metadata = file.metadata()?;
            if !metadata.is_dir()
                || metadata.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT.0 != 0
            {
                return Err(io::Error::other(
                    "Destination component is not an ordinary directory",
                ));
            }
            components.push(file);
        }
        Ok(Self {
            path: path.canonicalize()?,
            _components: components,
        })
    }
}

impl StagingLease {
    pub(crate) fn matches_view_item(&self, item: &Path) -> bool {
        // Resolve only the parent: following an unrelated leaf reparse point
        // could incorrectly treat a link to our file as the owned entry.
        let Some(parent) = item.parent().and_then(|parent| parent.canonicalize().ok()) else {
            return false;
        };
        self.path.parent() == Some(parent.as_path())
            && item.file_name().is_some()
            && item.file_name() == self.path.file_name()
            && open_staging(item, 0)
                .and_then(|file| staging_snapshot(&file))
                .ok()
                == Some(self.snapshot)
    }
}

fn windows_io(error: windows::core::Error) -> io::Error {
    let hresult = error.code().0 as u32;
    if hresult & 0xffff0000 == 0x80070000 {
        io::Error::from_raw_os_error((hresult & 0xffff) as i32)
    } else {
        io::Error::other(error.to_string())
    }
}

fn staging_snapshot(file: &File) -> io::Result<StagingSnapshot> {
    let metadata = file.metadata()?;
    if !metadata.is_file() || metadata.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT.0 != 0 {
        return Err(io::Error::other("Staging is not an ordinary file"));
    }
    let mut id = FILE_ID_INFO::default();
    // SAFETY: This live File owns the handle; the output buffer has the exact
    // type and size required by FileIdInfo and remains valid through the call.
    unsafe {
        GetFileInformationByHandleEx(
            HANDLE(file.as_raw_handle()),
            FileIdInfo,
            (&raw mut id).cast(),
            size_of::<FILE_ID_INFO>() as u32,
        )
    }
    .map_err(windows_io)?;
    if id.FileId.Identifier == [0; 16] {
        return Err(io::Error::new(
            io::ErrorKind::Unsupported,
            "No usable staging identity",
        ));
    }
    Ok(StagingSnapshot {
        identity: FileIdentity {
            volume: id.VolumeSerialNumber,
            id: id.FileId.Identifier,
            created: metadata.creation_time(),
        },
        length: metadata.file_size(),
        written: metadata.last_write_time(),
    })
}

fn open_staging(path: &Path, access: u32) -> io::Result<File> {
    OpenOptions::new()
        .access_mode(access | FILE_READ_ATTRIBUTES.0)
        .share_mode(FILE_SHARE_READ.0)
        .custom_flags(FILE_FLAG_OPEN_REPARSE_POINT.0)
        .open(path)
}

fn cleanup_staging(staging: &OwnedStaging) -> io::Result<()> {
    let file = match open_staging(&staging.path, DELETE.0) {
        Ok(file) => file,
        Err(error) if error.raw_os_error() == Some(2) => return Ok(()),
        Err(error) => return Err(error),
    };
    // Denying write/delete sharing keeps this exact object stable between the
    // identity check and disposition update. Never delete a replacement path.
    let actual = staging_snapshot(&file)?;
    if actual != staging.snapshot {
        #[cfg(test)]
        eprintln!(
            "Staging cleanup proof changed: expected={:?}, actual={actual:?}",
            staging.snapshot
        );
        return Ok(());
    }
    let disposition = FILE_DISPOSITION_INFO { DeleteFile: true };
    // SAFETY: The verified file is held with DELETE access and no write/delete
    // sharing. Disposition targets that handle, not a newly resolved pathname.
    unsafe {
        SetFileInformationByHandle(
            HANDLE(file.as_raw_handle()),
            FileDispositionInfo,
            (&raw const disposition).cast(),
            size_of::<FILE_DISPOSITION_INFO>() as u32,
        )
    }
    .map_err(windows_io)
}

fn remember_cleanup(staging: OwnedStaging) {
    #[cfg(test)]
    eprintln!("Retaining staging cleanup proof: {:?}", staging.snapshot);
    if let Ok(mut pending) = PENDING_CLEANUPS.lock() {
        retain_cleanup(&mut pending, staging);
    }
}

fn retain_cleanup(pending: &mut VecDeque<OwnedStaging>, staging: OwnedStaging) {
    if pending.len() == MAX_PENDING_CLEANUPS {
        pending.pop_front();
    }
    pending.push_back(staging);
}

fn cleanup_batch(pending: &mut VecDeque<OwnedStaging>, directory: &Path) -> Vec<OwnedStaging> {
    let mut selected = Vec::new();
    for _ in 0..MAX_CLEANUPS_PER_PASTE {
        let Some(index) = pending
            .iter()
            .position(|entry| entry.path.parent() == Some(directory))
        else {
            break;
        };
        if let Some(entry) = pending.remove(index) {
            selected.push(entry)
        }
    }
    selected
}

fn retry_staging_cleanup(directory: &Path) {
    let selected = PENDING_CLEANUPS
        .lock()
        .ok()
        .map(|mut pending| cleanup_batch(&mut pending, directory))
        .unwrap_or_default();
    #[cfg(test)]
    eprintln!("Deferred staging cleanup batch: {}", selected.len());
    // No filesystem operations run while the process-wide queue is locked.
    // Unavailable destinations wait for another paste, never a polling loop.
    for entry in selected {
        if cleanup_staging(&entry).is_err() {
            remember_cleanup(entry)
        }
    }
}

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
    identity: Option<FileIdentity>,
    snapshot: Option<StagingSnapshot>,
    closed: bool,
}

impl PendingFile {
    fn close_staging(&mut self) {
        if self.closed {
            return;
        }
        self.closed = true;
        self.file.take();
        // Refresh after closing when possible. A disconnected destination must
        // not discard a completed snapshot captured from our exclusive handle.
        // Its write time was frozen before encoding, so closing our handle
        // cannot invalidate that proof. A successful mismatch revokes it.
        if let (Some(path), Some(identity)) = (self.path.as_deref(), self.identity) {
            self.snapshot = match open_staging(path, 0).and_then(|file| staging_snapshot(&file)) {
                Ok(snapshot) => (snapshot.identity == identity).then_some(snapshot),
                Err(_) => self
                    .snapshot
                    .filter(|snapshot| snapshot.identity == identity),
            };
        }
    }
}

impl Drop for PendingFile {
    fn drop(&mut self) {
        self.close_staging();
        if let Some(path) = self.path.take() {
            if let Some(snapshot) = self.snapshot {
                let staging = OwnedStaging { path, snapshot };
                if cleanup_staging(&staging).is_err() {
                    remember_cleanup(staging)
                }
            }
        }
    }
}

fn reserve_staging_file(directory: &Path) -> io::Result<PendingFile> {
    for _ in 0..1024 {
        let mut id = NEXT_TEMPORARY_ID.load(Ordering::Relaxed);
        loop {
            let next = id
                .checked_add(1)
                .ok_or_else(|| io::Error::other("Staging identifiers exhausted"))?;
            match NEXT_TEMPORARY_ID.compare_exchange_weak(
                id,
                next,
                Ordering::Relaxed,
                Ordering::Relaxed,
            ) {
                Ok(_) => break,
                Err(observed) => id = observed,
            }
        }
        let path = directory.join(format!(".laqay-{}-{id}.tmp", std::process::id()));
        match OpenOptions::new()
            .read(true)
            .write(true)
            .access_mode(FILE_GENERIC_READ.0 | FILE_GENERIC_WRITE.0 | DELETE.0)
            .create_new(true)
            .share_mode(FILE_SHARE_READ.0)
            .open(&path)
        {
            Ok(file) => {
                let pending = PendingFile {
                    path: Some(path),
                    identity: staging_snapshot(&file)
                        .ok()
                        .map(|snapshot| snapshot.identity),
                    file: Some(file),
                    snapshot: None,
                    closed: false,
                };
                let file = pending
                    .file
                    .as_ref()
                    .ok_or_else(|| io::Error::other("Missing staging handle"))?;
                let preserve = FILETIME {
                    dwLowDateTime: u32::MAX,
                    dwHighDateTime: u32::MAX,
                };
                // SAFETY: This newly created, owned handle has WRITE_ATTRIBUTES.
                // Windows' documented sentinel preserves its initial write time
                // for this handle's lifetime; it does not backdate the file.
                // Deferred cleanup can then verify an offline snapshot after
                // close without accepting arbitrary size/time changes.
                unsafe { SetFileTime(HANDLE(file.as_raw_handle()), None, None, Some(&preserve)) }
                    .map_err(windows_io)?;
                return Ok(pending);
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

fn rename_staging(file: &File, destination: &Path) -> io::Result<()> {
    let name = wide_path(destination)?;
    let name_bytes = (name.len() - 1)
        .checked_mul(size_of::<u16>())
        .and_then(|bytes| u32::try_from(bytes).ok())
        .ok_or_else(|| io::Error::other("Destination name is too long"))?;
    let size = std::mem::offset_of!(FILE_RENAME_INFO, FileName)
        .checked_add(size_of_val(name.as_slice()))
        .ok_or_else(|| io::Error::other("Rename information is too large"))?
        .max(size_of::<FILE_RENAME_INFO>());
    let bytes = u32::try_from(size).map_err(|_| io::Error::other("Rename buffer is too large"))?;
    // usize storage provides at least FILE_RENAME_INFO alignment on Windows.
    let mut storage = vec![0usize; size.div_ceil(size_of::<usize>())];
    let info = storage.as_mut_ptr().cast::<FILE_RENAME_INFO>();
    // SAFETY: The aligned allocation contains the complete header and trailing
    // UTF-16 name including NUL. FileNameLength excludes NUL. Zeroed flags mean
    // ReplaceIfExists=false. The source is the original live file handle; the
    // absolute destination's directory chain is pinned by DirectoryLease.
    unsafe {
        info.write(FILE_RENAME_INFO {
            FileNameLength: name_bytes,
            ..Default::default()
        });
        std::ptr::copy_nonoverlapping(
            name.as_ptr(),
            storage
                .as_mut_ptr()
                .cast::<u8>()
                .add(std::mem::offset_of!(FILE_RENAME_INFO, FileName))
                .cast::<u16>(),
            name.len(),
        );
        SetFileInformationByHandle(
            HANDLE(file.as_raw_handle()),
            FileRenameInfo,
            info.cast(),
            bytes,
        )
    }
    .map_err(windows_io)
}

/// Encode a complete PNG into a staging file and rename it to an unused final name.
/// The encoder must produce valid PNG bytes and must not retain the file handle.
/// Context authorization, PNG validation, and Shell notification belong to the caller.
/// Failed cleanup retains at most 32 verified records in this process. A later
/// paste in the same directory retries up to four; replacements and changed
/// size/write-time evidence are preserved. Unknown identity or process exit can
/// still leave a .tmp file. No failed encoding is published as a PNG.
pub fn create_screenshot(
    directory: &Path,
    time: ScreenshotTime,
    encode: impl FnOnce(&mut File) -> io::Result<()>,
) -> io::Result<PathBuf> {
    create_screenshot_checked(directory, time, encode, || Ok(()))
}

/// Revalidate the caller's paste context immediately before each publication
/// attempt. Cancellation removes staging data without publishing a PNG.
pub fn create_screenshot_checked(
    directory: &Path,
    time: ScreenshotTime,
    encode: impl FnOnce(&mut File) -> io::Result<()>,
    mut before_publish: impl FnMut() -> io::Result<()>,
) -> io::Result<PathBuf> {
    create_screenshot_with_staging_checked(directory, time, encode, |_| before_publish())
}

pub(crate) fn create_screenshot_with_staging_checked(
    directory: &Path,
    time: ScreenshotTime,
    encode: impl FnOnce(&mut File) -> io::Result<()>,
    mut before_publish: impl FnMut(StagingContext<'_>) -> io::Result<()>,
) -> io::Result<PathBuf> {
    if !directory.is_absolute() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "An absolute destination is required",
        ));
    }
    // Validate the path before creating any output.
    wide_path(directory)?;
    let directory_lease = DirectoryLease::pin(directory)?;
    let directory = directory_lease.path.as_path();
    retry_staging_cleanup(directory);
    let mut pending = reserve_staging_file(directory)?;
    let file = pending
        .file
        .as_mut()
        .ok_or_else(|| io::Error::other("Missing staging handle"))?;
    let encoded = encode(file).and_then(|()| file.sync_all());
    encoded?;
    // Commit an explicit completion time before collecting evidence. In
    // particular, a server-forced SMB close must not apply a deferred write
    // timestamp that differs from the completed snapshot retained for cleanup.
    file.set_times(fs::FileTimes::new().set_modified(std::time::SystemTime::now()))?;
    let completed = staging_snapshot(file)?;
    pending.identity = Some(completed.identity);
    pending.snapshot = Some(completed);
    let mut collision = 0;
    loop {
        before_publish(StagingContext {
            path: pending
                .path
                .as_deref()
                .ok_or_else(|| io::Error::other("Missing staging path"))?,
            snapshot: pending.snapshot,
            file: pending
                .file
                .as_ref()
                .ok_or_else(|| io::Error::other("Missing staging handle"))?,
        })?;
        let destination = directory.join(time.filename(collision));
        let result = rename_staging(
            pending
                .file
                .as_ref()
                .ok_or_else(|| io::Error::other("Missing staging handle"))?,
            &destination,
        );
        match result {
            Ok(()) => {
                pending.path.take();
                return Ok(destination);
            }
            Err(error) => {
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

    #[test]
    fn staging_lease_pins_only_the_completed_owned_entry_until_publication() {
        let directory = TestDirectory::new();
        let other = TestDirectory::new();
        let mut encodes = 0;
        let output = create_screenshot_with_staging_checked(
            &directory.0,
            time(),
            |file| {
                encodes += 1;
                file.write_all(b"complete image")
            },
            |context| {
                let lease = context.pin()?;
                assert!(lease.matches_view_item(context.path));
                assert!(!lease.matches_view_item(&directory.0.join(".laqay-foreign.tmp")));
                assert!(!lease.matches_view_item(&other.0.join(context.path.file_name().unwrap())));
                assert!(OpenOptions::new().write(true).open(context.path).is_err());
                assert!(fs::remove_file(context.path).is_err());
                assert_eq!(fs::read(context.path)?, b"complete image");
                Ok(())
            },
        )
        .unwrap();
        assert_eq!(encodes, 1);
        assert_eq!(fs::read(output).unwrap(), b"complete image");
        assert_eq!(fs::read_dir(&directory.0).unwrap().count(), 1);
    }

    #[test]
    fn staging_remains_exclusive_before_during_and_after_context_observation() {
        let directory = TestDirectory::new();
        let mut completed = None;
        let output = create_screenshot_with_staging_checked(
            &directory.0,
            time(),
            |file| file.write_all(b"original encoded image"),
            |context| {
                completed = context.snapshot;
                let tamper = || {
                    assert!(fs::write(context.path, b"changed").is_err());
                    assert!(fs::remove_file(context.path).is_err());
                    assert!(
                        fs::rename(context.path, context.path.with_extension("retained")).is_err()
                    );
                };
                tamper();
                let lease = context.pin()?;
                assert!(lease.matches_view_item(context.path));
                tamper();
                drop(lease);
                // Publication must not reopen an unlocked source pathname.
                tamper();
                Ok(())
            },
        )
        .unwrap();
        assert_eq!(fs::read(&output).unwrap(), b"original encoded image");
        // The cleanup evidence survives rename and close, including write time.
        assert!(Some(staging_snapshot(&File::open(&output).unwrap()).unwrap()) == completed);
        assert_eq!(fs::read_dir(&directory.0).unwrap().count(), 1);
    }

    #[test]
    fn destination_and_ancestor_cannot_be_renamed_during_encoding_or_publication() {
        let ancestor = TestDirectory::new();
        let directory = ancestor.0.join("destination");
        fs::create_dir(&directory).unwrap();
        let moved = ancestor.0.with_extension("moved");
        let tamper = || {
            assert!(fs::rename(&directory, ancestor.0.join("replacement")).is_err());
            assert!(fs::rename(&ancestor.0, &moved).is_err());
        };
        let output = create_screenshot_checked(
            &directory,
            time(),
            |file| {
                tamper();
                file.write_all(b"original image")
            },
            || {
                tamper();
                Ok(())
            },
        )
        .unwrap();
        assert_eq!(fs::read(&output).unwrap(), b"original image");
        // All directory handles are released when the operation returns.
        fs::rename(&ancestor.0, &moved).unwrap();
        fs::rename(&moved, &ancestor.0).unwrap();
        fs::remove_file(output).unwrap();
        fs::remove_dir(directory).unwrap();
    }

    #[test]
    fn a_junction_at_the_supplied_destination_is_rejected_before_encoding() {
        use std::{
            os::windows::process::CommandExt,
            process::{Command, Stdio},
            time::{Duration, Instant},
        };
        use windows::Win32::System::Threading::CREATE_NO_WINDOW;

        let parent = TestDirectory::new();
        let other = TestDirectory::new();
        let link = parent.0.join("redirected");
        // Junction creation needs no administrator or Developer Mode. Paths
        // travel as environment values, never interpolated command text.
        let mut child = Command::new("powershell.exe")
            .creation_flags(CREATE_NO_WINDOW.0)
            .args(["-NoProfile", "-NonInteractive", "-Command",
                "$ErrorActionPreference='Stop'; New-Item -ItemType Junction -Path $env:LAQAY_JUNCTION_LINK -Target $env:LAQAY_JUNCTION_TARGET | Out-Null"])
            .env("LAQAY_JUNCTION_LINK", &link)
            .env("LAQAY_JUNCTION_TARGET", &other.0)
            .stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null())
            .spawn().unwrap();
        let deadline = Instant::now() + Duration::from_secs(30);
        let status = loop {
            if let Some(status) = child.try_wait().unwrap() {
                break status;
            }
            if Instant::now() >= deadline {
                child.kill().unwrap();
                child.wait().unwrap();
                panic!("Junction fixture preparation exceeded its deadline");
            }
            std::thread::sleep(Duration::from_millis(10));
        };
        assert!(status.success(), "Junction fixture preparation failed");
        struct Junction(PathBuf);
        impl Drop for Junction {
            fn drop(&mut self) {
                fs::remove_dir(&self.0).unwrap();
            }
        }
        let junction = Junction(link);
        assert_ne!(
            fs::symlink_metadata(&junction.0).unwrap().file_attributes()
                & FILE_ATTRIBUTE_REPARSE_POINT.0,
            0
        );
        let result = create_screenshot(&junction.0, time(), |_| panic!("must not encode"));
        assert!(result.is_err());
        assert_eq!(fs::read_dir(&other.0).unwrap().count(), 0);
    }

    #[test]
    fn staging_lease_rejects_unknown_identity() {
        let directory = TestDirectory::new();
        let result = create_screenshot_with_staging_checked(
            &directory.0,
            time(),
            |file| file.write_all(b"complete image"),
            |context| {
                assert!(
                    StagingContext {
                        path: context.path,
                        snapshot: None,
                        file: context.file,
                    }
                    .pin()
                    .is_err()
                );
                Err(io::Error::new(
                    io::ErrorKind::Interrupted,
                    "Unknown staging",
                ))
            },
        );
        assert!(result.is_err());
        assert_eq!(fs::read_dir(&directory.0).unwrap().count(), 0);
    }

    #[test]
    fn empty_view_excludes_only_one_verified_owned_entry() {
        use crate::explorer::view_is_logically_empty;
        let directory = TestDirectory::new();
        let output = create_screenshot_with_staging_checked(
            &directory.0,
            time(),
            |file| file.write_all(b"image"),
            |context| {
                let lease = context.pin()?;
                assert!(
                    view_is_logically_empty(0, None, || panic!(
                        "An empty view requested an item path"
                    ))
                    .unwrap()
                );
                assert!(
                    !view_is_logically_empty(1, None, || panic!(
                        "An unverified view requested an item path"
                    ))
                    .unwrap()
                );
                for count in [-1, 2, 3] {
                    assert!(
                        !view_is_logically_empty(count, Some(&lease), || panic!(
                            "A foreign or unknown item count requested an exclusion"
                        ))
                        .unwrap()
                    );
                }
                assert!(
                    view_is_logically_empty(1, Some(&lease), || Ok(context.path.to_owned()))
                        .unwrap()
                );
                assert!(
                    !view_is_logically_empty(1, Some(&lease), || Ok(directory
                        .0
                        .join(".laqay-foreign.tmp")))
                    .unwrap()
                );
                assert!(
                    view_is_logically_empty(1, Some(&lease), || Err(
                        windows::core::Error::from_hresult(windows::Win32::Foundation::E_FAIL)
                    ))
                    .is_err()
                );
                Ok(())
            },
        )
        .unwrap();
        assert_eq!(fs::read(output).unwrap(), b"image");
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
    fn encoder_unwind_removes_the_owned_staging_file() {
        let directory = TestDirectory::new();
        let panic = std::panic::catch_unwind(|| {
            let _ = create_screenshot(&directory.0, time(), |file| {
                file.write_all(b"partial before unwind")?;
                panic!("Synthetic encoder panic");
            });
        });
        assert!(panic.is_err());
        assert_eq!(fs::read_dir(&directory.0).unwrap().count(), 0);
    }

    #[test]
    fn encoding_failure_keeps_staging_exclusive_until_cleanup() {
        let directory = TestDirectory::new();
        let mut path = None;
        let result = create_screenshot(&directory.0, time(), |file| {
            file.write_all(b"failed encoded data")?;
            let entry = fs::read_dir(&directory.0)?.next().unwrap()?;
            path = Some(entry.path());
            assert!(
                OpenOptions::new()
                    .read(true)
                    .share_mode(FILE_SHARE_READ.0 | FILE_SHARE_WRITE.0)
                    .open(entry.path())
                    .is_err()
            );
            Err(io::Error::other("Synthetic encoding failure"))
        });
        assert_eq!(
            result.unwrap_err().to_string(),
            "Synthetic encoding failure"
        );
        let staging = path.unwrap();
        assert!(!staging.exists());
        create_screenshot(&directory.0, time(), |file| file.write_all(b"fresh image")).unwrap();
        assert!(!staging.exists());
        assert_eq!(fs::read_dir(&directory.0).unwrap().count(), 1);
    }

    fn hold_failed_staging(directory: &Path) -> (PathBuf, File) {
        // Exercise deferred cleanup of a closed file independently of the new
        // continuous writer lock, which now prevents this reader from opening
        // during successful encoding/publication.
        let path = directory.canonicalize().unwrap().join(format!(
            ".laqay-{}-{}.tmp",
            std::process::id(),
            NEXT_TEMPORARY_ID.fetch_add(1, Ordering::Relaxed)
        ));
        fs::write(&path, b"staged image").unwrap();
        let held = OpenOptions::new()
            .read(true)
            .share_mode(FILE_SHARE_READ.0)
            .open(&path)
            .unwrap();
        let staging = OwnedStaging {
            path: path.clone(),
            snapshot: staging_snapshot(&held).unwrap(),
        };
        assert!(cleanup_staging(&staging).is_err());
        remember_cleanup(staging);
        (path, held)
    }

    #[test]
    fn a_later_paste_removes_its_own_failed_staging_after_recovery() {
        let directory = TestDirectory::new();
        let (staging, held) = hold_failed_staging(&directory.0);
        drop(held);
        let output =
            create_screenshot(&directory.0, time(), |file| file.write_all(b"fresh image")).unwrap();
        assert!(!staging.exists());
        assert_eq!(fs::read(output).unwrap(), b"fresh image");
        assert_eq!(fs::read_dir(&directory.0).unwrap().count(), 1);
    }

    #[test]
    fn cleanup_preserves_a_replacement_at_the_recorded_path() {
        let directory = TestDirectory::new();
        let (staging, held) = hold_failed_staging(&directory.0);
        let original_id = staging_snapshot(&held).unwrap().identity.id;
        drop(held);
        fs::remove_file(&staging).unwrap();
        fs::write(&staging, b"foreign data").unwrap();
        assert!(
            staging_snapshot(&File::open(&staging).unwrap())
                .unwrap()
                .identity
                .id
                != original_id
        );
        create_screenshot(&directory.0, time(), |file| file.write_all(b"fresh image")).unwrap();
        assert_eq!(fs::read(staging).unwrap(), b"foreign data");
    }

    #[test]
    fn cleanup_preserves_in_place_edits_with_changed_write_time() {
        let directory = TestDirectory::new();
        let (staging, held) = hold_failed_staging(&directory.0);
        drop(held);
        fs::write(&staging, b"changed data").unwrap();
        let modified = std::time::UNIX_EPOCH + std::time::Duration::from_secs(1_600_000_000);
        OpenOptions::new()
            .write(true)
            .open(&staging)
            .unwrap()
            .set_times(fs::FileTimes::new().set_modified(modified))
            .unwrap();
        create_screenshot(&directory.0, time(), |file| file.write_all(b"fresh image")).unwrap();
        assert_eq!(fs::read(staging).unwrap(), b"changed data");
    }

    #[test]
    fn cleanup_does_not_scan_lookalike_files_or_other_destinations() {
        let directory = TestDirectory::new();
        let other = TestDirectory::new();
        let (staging, held) = hold_failed_staging(&directory.0);
        drop(held);
        let lookalike = directory
            .0
            .join(format!(".laqay-{}-999999999.tmp", std::process::id()));
        fs::write(&lookalike, b"untracked data").unwrap();
        create_screenshot(&other.0, time(), |file| file.write_all(b"other image")).unwrap();
        assert!(staging.exists());
        create_screenshot(&directory.0, time(), |file| file.write_all(b"fresh image")).unwrap();
        assert!(!staging.exists());
        assert_eq!(fs::read(lookalike).unwrap(), b"untracked data");
    }

    #[test]
    fn cleanup_records_and_per_paste_work_are_bounded() {
        let mut pending = VecDeque::new();
        let parent = Path::new(r"C:\fixture-a");
        for index in 0..MAX_PENDING_CLEANUPS + 1 {
            let directory = if index % 2 == 0 {
                parent
            } else {
                Path::new(r"C:\fixture-b")
            };
            retain_cleanup(
                &mut pending,
                OwnedStaging {
                    path: directory.join(format!("{index}.tmp")),
                    snapshot: StagingSnapshot {
                        identity: FileIdentity {
                            volume: 1,
                            id: [1; 16],
                            created: 1,
                        },
                        length: 1,
                        written: 1,
                    },
                },
            );
        }
        assert_eq!(pending.len(), MAX_PENDING_CLEANUPS);
        assert!(
            pending
                .iter()
                .all(|entry| entry.path.file_name().unwrap() != "0.tmp")
        );
        let batch = cleanup_batch(&mut pending, parent);
        assert_eq!(batch.len(), MAX_CLEANUPS_PER_PASTE);
        assert!(
            batch
                .iter()
                .all(|entry| entry.path.parent() == Some(parent))
        );
        assert_eq!(pending.len(), MAX_PENDING_CLEANUPS - MAX_CLEANUPS_PER_PASTE);
        assert!(cleanup_batch(&mut pending, Path::new(r"C:\absent")).is_empty());
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

    #[test]
    fn cancellation_after_encoding_never_publishes_a_png() {
        let directory = TestDirectory::new();
        let result = create_screenshot_checked(
            &directory.0,
            time(),
            |file| file.write_all(b"complete"),
            || {
                Err(io::Error::new(
                    io::ErrorKind::Interrupted,
                    "context changed",
                ))
            },
        );
        assert_eq!(result.unwrap_err().kind(), io::ErrorKind::Interrupted);
        assert_eq!(fs::read_dir(&directory.0).unwrap().count(), 0);
    }

    #[test]
    fn cancelled_generation_stops_collision_retries_and_recovers() {
        let directory = TestDirectory::new();
        let original = directory.0.join(time().filename(0));
        fs::write(&original, b"original").unwrap();
        let activity = crate::activity::Activity::new(true);
        let ticket = activity.ticket().unwrap();
        let mut validations = 0;
        let result = create_screenshot_checked(
            &directory.0,
            time(),
            |file| file.write_all(b"cancelled image"),
            || {
                validations += 1;
                if !activity.valid(ticket) {
                    return Err(io::Error::new(
                        io::ErrorKind::Interrupted,
                        "Cancelled generation",
                    ));
                }
                // Revoke the first authorization before its occupied name
                // forces another publication attempt. Re-enabling is a new ticket.
                activity.set_enabled(false);
                activity.set_enabled(true);
                Ok(())
            },
        );
        assert_eq!(result.unwrap_err().kind(), io::ErrorKind::Interrupted);
        assert_eq!(validations, 2);
        assert_eq!(fs::read(&original).unwrap(), b"original");
        assert_eq!(fs::read_dir(&directory.0).unwrap().count(), 1);
        let current = activity.ticket().unwrap();
        assert!(!activity.valid(ticket));
        let output = create_screenshot_checked(
            &directory.0,
            time(),
            |file| file.write_all(b"new image"),
            || {
                assert!(activity.valid(current));
                Ok(())
            },
        )
        .unwrap();
        assert_eq!(output.file_name().unwrap(), time().filename(1).as_str());
        assert_eq!(fs::read(output).unwrap(), b"new image");
        assert_eq!(fs::read(original).unwrap(), b"original");
        assert_eq!(fs::read_dir(&directory.0).unwrap().count(), 2);
    }

    #[test]
    fn pause_and_resume_during_staging_cannot_revive_the_write() {
        let directory = TestDirectory::new();
        let activity = crate::activity::Activity::new(true);
        let ticket = activity.ticket().unwrap();
        let (staged_tx, staged_rx) = std::sync::mpsc::channel();
        let (resume_tx, resume_rx) = std::sync::mpsc::channel();
        let timeout = std::time::Duration::from_secs(5);
        let result = std::thread::scope(|scope| {
            let folder = &directory.0;
            let gate = &activity;
            let writer = scope.spawn(move || {
                create_screenshot_checked(
                    folder,
                    time(),
                    |file| {
                        file.write_all(b"complete staged data")?;
                        staged_tx
                            .send(())
                            .map_err(|error| io::Error::other(error.to_string()))?;
                        resume_rx.recv_timeout(timeout).map_err(|error| {
                            io::Error::new(io::ErrorKind::TimedOut, error.to_string())
                        })?;
                        Ok(())
                    },
                    || {
                        if gate.valid(ticket) {
                            Ok(())
                        } else {
                            Err(io::Error::new(
                                io::ErrorKind::Interrupted,
                                "Cancelled generation",
                            ))
                        }
                    },
                )
            });
            staged_rx.recv_timeout(timeout).unwrap();
            activity.set_enabled(false);
            activity.set_enabled(true);
            resume_tx.send(()).unwrap();
            writer.join().unwrap()
        });
        assert_eq!(result.unwrap_err().kind(), io::ErrorKind::Interrupted);
        assert_eq!(fs::read_dir(&directory.0).unwrap().count(), 0);
    }

    #[test]
    fn a_regular_file_destination_is_rejected_without_encoding_or_overwrite() {
        let directory = TestDirectory::new();
        let path = directory.0.join("original-file");
        fs::write(&path, b"original").unwrap();
        let result = create_screenshot(&path, time(), |_| panic!("must not encode"));
        assert!(result.is_err());
        assert_eq!(fs::read(path).unwrap(), b"original");
        assert_eq!(fs::read_dir(&directory.0).unwrap().count(), 1);
    }
}
