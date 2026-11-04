//! Opt-in real-capacity tests on a controller-owned small CI volume.

use std::{
    fs::{self, OpenOptions},
    io::{self, Write},
    os::windows::{ffi::OsStrExt, fs::MetadataExt},
    path::{Path, PathBuf},
};
use windows::{
    Win32::Storage::FileSystem::{GetDiskFreeSpaceExW, GetVolumeInformationW},
    core::PCWSTR,
};

fn space(root: &Path) -> (u64, u64) {
    let wide: Vec<_> = root.as_os_str().encode_wide().chain(Some(0)).collect();
    let (mut free, mut total) = (0, 0);
    // SAFETY: The root is NUL-terminated and all output pointers remain live.
    unsafe {
        GetDiskFreeSpaceExW(
            PCWSTR(wide.as_ptr()),
            Some(&mut free),
            Some(&mut total),
            None,
        )
        .unwrap();
    }
    (free, total)
}

fn full(error: &io::Error) -> bool {
    matches!(error.raw_os_error(), Some(39 | 112))
}

#[test]
#[ignore = "Requires the dedicated 64 MiB NTFS volume from the hosted CI harness"]
fn disk_full_cleans_failed_write_and_recovers() {
    for (name, expected) in [
        ("GITHUB_ACTIONS", "true"),
        ("RUNNER_ENVIRONMENT", "github-hosted"),
        ("RUNNER_OS", "Windows"),
    ] {
        assert_eq!(std::env::var(name).as_deref(), Ok(expected));
    }
    let token = std::env::var("LAQAY_STORAGE_TEST_TOKEN").unwrap();
    assert_eq!(token.len(), 32);
    assert!(token.bytes().all(|c| c.is_ascii_hexdigit()));
    let directory = PathBuf::from(std::env::var_os("LAQAY_STORAGE_TEST_ROOT").unwrap());
    let volume = directory.parent().unwrap();
    let volume_text = volume.to_str().unwrap();
    assert_eq!(volume_text.len(), 3);
    assert!(matches!(volume_text.as_bytes()[0], b'R'..=b'Z'));
    assert_eq!(&volume_text[1..], ":\\");
    assert_eq!(
        directory.file_name().unwrap(),
        format!("LaqayStorageTest-{token}").as_str()
    );
    assert_eq!(
        fs::symlink_metadata(&directory).unwrap().file_attributes() & 0x400,
        0
    );
    assert_eq!(
        fs::read_to_string(directory.join("owner.txt")).unwrap(),
        token
    );
    assert_eq!(fs::read_dir(&directory).unwrap().count(), 1);
    let wide: Vec<_> = volume.as_os_str().encode_wide().chain(Some(0)).collect();
    let (mut label, mut filesystem) = ([0u16; 64], [0u16; 32]);
    // SAFETY: The root and bounded mutable output buffers live through the call.
    unsafe {
        GetVolumeInformationW(
            PCWSTR(wide.as_ptr()),
            Some(&mut label),
            None,
            None,
            None,
            Some(&mut filesystem),
        )
        .unwrap();
    }
    let text = |value: &[u16]| {
        String::from_utf16(&value[..value.iter().position(|&c| c == 0).unwrap()]).unwrap()
    };
    assert_eq!(text(&filesystem), "NTFS");
    assert_eq!(
        text(&label),
        format!("LQST{}", token[..8].to_ascii_uppercase())
    );
    let (_, total) = space(volume);
    assert!((32 * 1024 * 1024..=64 * 1024 * 1024).contains(&total));

    let mut dib = vec![0u8; 40 + 512 * 512 * 3];
    dib[..4].copy_from_slice(&40u32.to_le_bytes());
    dib[4..8].copy_from_slice(&512i32.to_le_bytes());
    dib[8..12].copy_from_slice(&512i32.to_le_bytes());
    dib[12..14].copy_from_slice(&1u16.to_le_bytes());
    dib[14..16].copy_from_slice(&24u16.to_le_bytes());
    let mut random = 0x1357_2468u32;
    for byte in &mut dib[40..] {
        random ^= random << 13;
        random ^= random >> 17;
        random ^= random << 5;
        *byte = random as u8;
    }
    let png = crate::image::to_png(&dib, false).unwrap();
    assert!(png.len() > 64 * 1024);
    let time = crate::file_writer::ScreenshotTime::new(2026, 11, 4, 1, 2, 3).unwrap();
    let original = directory.join(time.filename(0));
    fs::write(&original, &png).unwrap();
    let filler_path = directory.join("filler.bin");
    let mut filler = OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&filler_path)
        .unwrap();
    let block = [0x5au8; 64 * 1024];
    let mut written = 0u64;
    let fill_error = loop {
        assert!(
            written < 64 * 1024 * 1024,
            "The bounded volume did not fill"
        );
        match filler.write(&block) {
            Ok(0) => panic!("The filler stopped without a capacity error"),
            Ok(count) => written += count as u64,
            Err(error) => {
                assert!(full(&error), "{error}");
                break error.raw_os_error().unwrap();
            }
        }
    };
    if let Err(error) = filler.sync_all() {
        assert!(full(&error), "{error}");
    }
    drop(filler);
    let (free, _) = space(volume);
    assert!(free < png.len() as u64);
    let error =
        crate::file_writer::create_screenshot(&directory, time, |file| file.write_all(&png))
            .unwrap_err();
    assert!(full(&error), "{error}");
    let writer_error = error.raw_os_error().unwrap();
    assert_eq!(fs::read(&original).unwrap(), png);
    assert_eq!(fs::read_dir(&directory).unwrap().count(), 3);
    assert!(!directory.join(time.filename(1)).exists());
    fs::remove_file(filler_path).unwrap();
    let output =
        crate::file_writer::create_screenshot(&directory, time, |file| file.write_all(&png))
            .unwrap();
    assert_eq!(output.file_name().unwrap(), time.filename(1).as_str());
    assert_eq!(
        crate::image::to_png(&fs::read(&output).unwrap(), true).unwrap(),
        png
    );
    assert_eq!(fs::read(&original).unwrap(), png);
    assert_eq!(fs::read_dir(&directory).unwrap().count(), 3);
    fs::remove_file(output).unwrap();
    fs::remove_file(original).unwrap();
    assert_eq!(fs::read_dir(&directory).unwrap().count(), 1);
    println!(
        "LAQAY_STORAGE_RESULT {{\"fill_error\":{fill_error},\"writer_error\":{writer_error},\"free_bytes\":{free},\"filled_bytes\":{written},\"recovered\":true,\"original_preserved\":true,\"no_staging\":true}}"
    );
}
