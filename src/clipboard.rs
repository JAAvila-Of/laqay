//! Read an image only for an explicit paste request; never change clipboard data.

use crate::image::MAX_IMAGE_BYTES;
use crate::{ClipboardFormats, ImageFormat};
use windows::{
    Win32::{
        Foundation::{E_INVALIDARG, HGLOBAL},
        Graphics::Gdi::HBITMAP,
        System::{
            DataExchange::{
                CloseClipboard, GetClipboardData, GetClipboardSequenceNumber,
                IsClipboardFormatAvailable, OpenClipboard, RegisterClipboardFormatW,
            },
            Memory::{GlobalLock, GlobalSize, GlobalUnlock},
        },
    },
    core::{Error, Result, w},
};

pub struct ClipboardImage {
    pub bytes: Vec<u8>,
    pub is_png: bool,
}

#[cfg(all(test, feature = "isolated-clipboard-tests"))]
#[path = "clipboard_tests.rs"]
mod tests;

struct Open;
impl Drop for Open {
    fn drop(&mut self) {
        // SAFETY: This guard is created only after this thread opens the clipboard.
        let _ = unsafe { CloseClipboard() };
    }
}
struct Locked(HGLOBAL);
impl Drop for Locked {
    fn drop(&mut self) {
        // SAFETY: This guard balances a successful GlobalLock and never frees the
        // clipboard-owned HGLOBAL. No pointer escapes the open clipboard lifetime.
        let _ = unsafe { GlobalUnlock(self.0) };
    }
}

/// Return supported image bytes only if the clipboard still matches the request.
/// File transfers, virtual files, unsupported bitmaps, and uncertain data decline.
pub fn read_image(expected_sequence: u32) -> Result<Option<ClipboardImage>> {
    // SAFETY: Clipboard access and HGLOBAL locks are scoped by guards. Availability
    // queries read no contents; only the chosen image representation is copied.
    unsafe {
        if expected_sequence == 0 || GetClipboardSequenceNumber() != expected_sequence {
            return Ok(None);
        }
        let mut shell_formats = Vec::new();
        for name in [
            w!("FileGroupDescriptorW"),
            w!("FileGroupDescriptor"),
            w!("FileContents"),
            w!("Shell IDList Array"),
            w!("Preferred DropEffect"),
            w!("FileNameW"),
            w!("FileName"),
            w!("Object Descriptor"),
            w!("Embed Source"),
            w!("Embedded Object"),
        ] {
            let format = RegisterClipboardFormatW(name);
            if format == 0 {
                return Err(Error::from_thread());
            }
            shell_formats.push(format);
        }
        if IsClipboardFormatAvailable(15).is_ok()
            || shell_formats
                .iter()
                .any(|format| IsClipboardFormatAvailable(*format).is_ok())
        {
            return Ok(None);
        }
        let png = RegisterClipboardFormatW(w!("PNG"));
        if png == 0 {
            return Err(Error::from_thread());
        }
        let available = ClipboardFormats {
            png: IsClipboardFormatAvailable(png).is_ok(),
            dib_v5: IsClipboardFormatAvailable(17).is_ok(),
            dib: IsClipboardFormatAvailable(8).is_ok(),
            bitmap: IsClipboardFormatAvailable(2).is_ok(),
            ..Default::default()
        };
        let (format, is_png) = match available.preferred_image() {
            Some(ImageFormat::Png) => (png, true),
            Some(ImageFormat::DibV5) => (17, false),
            Some(ImageFormat::Dib) => (8, false),
            Some(ImageFormat::Bitmap) => (2, false),
            None => return Ok(None),
        };
        // Decline ordinary file/text pastes before acquiring the clipboard lock.
        // After opening an image candidate, recheck sequence and file priority.
        if GetClipboardSequenceNumber() != expected_sequence {
            return Ok(None);
        }
        OpenClipboard(None)?;
        let _open = Open;
        if GetClipboardSequenceNumber() != expected_sequence
            || IsClipboardFormatAvailable(15).is_ok()
            || shell_formats
                .iter()
                .any(|format| IsClipboardFormatAvailable(*format).is_ok())
        {
            return Ok(None);
        }
        let image = copy_open_image(&_open, format, is_png)?;
        if GetClipboardSequenceNumber() != expected_sequence {
            return Ok(None);
        }
        Ok(Some(image))
    }
}

fn copy_open_image(_open: &Open, format: u32, is_png: bool) -> Result<ClipboardImage> {
    // SAFETY: The guard keeps this thread's clipboard open until the owned copy
    // is complete. CF_BITMAP is a borrowed GDI object, never an HGLOBAL.
    unsafe {
        let raw = GetClipboardData(format)?;
        if format == 2 {
            return Ok(ClipboardImage {
                bytes: crate::image::bitmap_to_dib(HBITMAP(raw.0))?,
                is_png: false,
            });
        }
        let handle = HGLOBAL(raw.0);
        let size = GlobalSize(handle);
        if size == 0 || size > MAX_IMAGE_BYTES {
            return Err(Error::from_hresult(E_INVALIDARG));
        }
        let data = GlobalLock(handle);
        if data.is_null() {
            return Err(Error::from_thread());
        }
        let _locked = Locked(handle);
        let bytes = std::slice::from_raw_parts(data.cast::<u8>(), size).to_vec();
        Ok(ClipboardImage { bytes, is_png })
    }
}
