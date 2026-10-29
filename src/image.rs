//! Bounded clipboard image conversion using the native Windows codecs.

use std::ptr::{null, null_mut};
use windows::{
    Win32::{
        Foundation::{E_FAIL, E_INVALIDARG, HGLOBAL},
        Graphics::Imaging::*,
        System::Com::{
            CLSCTX_INPROC_SERVER, COINIT_MULTITHREADED, CoCreateInstance, CoInitializeEx,
            CoUninitialize, STATFLAG_NONAME, STATSTG, STREAM_SEEK_SET,
            StructuredStorage::CreateStreamOnHGlobal,
        },
        UI::Shell::SHCreateMemStream,
    },
    core::{Error, Result},
};

pub const MAX_IMAGE_BYTES: usize = 128 * 1024 * 1024;
const PNG_SIGNATURE: &[u8] = b"\x89PNG\r\n\x1a\n";

fn png_extent(bytes: &[u8]) -> Result<usize> {
    if !bytes.starts_with(PNG_SIGNATURE) {
        return Err(invalid());
    }
    let mut position = 8usize;
    loop {
        let header_end = position
            .checked_add(8)
            .filter(|end| *end <= bytes.len())
            .ok_or_else(invalid)?;
        let length = u32::from_be_bytes(bytes[position..position + 4].try_into().unwrap()) as usize;
        let end = header_end
            .checked_add(length)
            .and_then(|n| n.checked_add(4))
            .filter(|end| *end <= bytes.len())
            .ok_or_else(invalid)?;
        if &bytes[position + 4..header_end] == b"IEND" {
            if length != 0 || bytes[header_end..end] != [0xae, 0x42, 0x60, 0x82] {
                return Err(invalid());
            }
            return Ok(end);
        }
        position = end;
    }
}

fn invalid() -> Error {
    Error::from_hresult(E_INVALIDARG)
}

/// Wrap supported packed DIB headers in a BMP container, preserving RGB and
/// declared alpha. An unused V5 alpha byte is normalized to opaque.
/// RLE, palettes, embedded profiles, and unusual bit masks are rejected for now.
pub fn dib_to_bmp(dib: &[u8]) -> Result<Vec<u8>> {
    if dib.len() < 40 || dib.len() > MAX_IMAGE_BYTES {
        return Err(invalid());
    }
    let u16_at = |offset| u16::from_le_bytes(dib[offset..offset + 2].try_into().unwrap());
    let u32_at = |offset| u32::from_le_bytes(dib[offset..offset + 4].try_into().unwrap());
    let header = u32_at(0) as usize;
    if ![40, 52, 56, 108, 124].contains(&header) || header > dib.len() {
        return Err(invalid());
    }
    let width = u32_at(4) as i32;
    let height = u32_at(8) as i32;
    let bits = u16_at(14);
    let compression = u32_at(16);
    if width <= 0
        || height == 0
        || height == i32::MIN
        || u16_at(12) != 1
        || ![24, 32].contains(&bits)
        || ![0, 3].contains(&compression)
        || (compression == 3 && bits != 32)
        || u32_at(32) != 0
    {
        return Err(invalid());
    }
    if header == 124 && (u32_at(112) != 0 || u32_at(116) != 0) {
        return Err(invalid());
    }
    if header >= 56 && header != 124 && u32_at(52) != 0 {
        return Err(invalid());
    }
    let external_masks = if compression == 3 && header == 40 {
        12
    } else {
        0
    };
    let offset = header + external_masks;
    if dib.len() < offset {
        return Err(invalid());
    }
    if compression == 3 {
        if u32_at(40) != 0x00ff0000 || u32_at(44) != 0x0000ff00 || u32_at(48) != 0x000000ff {
            return Err(invalid());
        }
        if header >= 56 && ![0, 0xff000000].contains(&u32_at(52)) {
            return Err(invalid());
        }
        // WIC's documented alpha-preserving BMP path requires a V5 header.
        if header != 124 && header >= 56 && u32_at(52) != 0 {
            return Err(invalid());
        }
    }
    let width = width as usize;
    let height = height.unsigned_abs() as usize;
    checked_rgba_size(width, height)?;
    let stride = width
        .checked_mul(bits as usize)
        .and_then(|n| n.checked_add(31))
        .map(|n| (n / 32) * 4)
        .ok_or_else(invalid)?;
    let end = stride
        .checked_mul(height)
        .and_then(|n| n.checked_add(offset))
        .ok_or_else(invalid)?;
    if end > dib.len() {
        return Err(invalid());
    }
    let total = dib
        .len()
        .checked_add(14)
        .filter(|n| *n <= MAX_IMAGE_BYTES)
        .ok_or_else(invalid)?;
    let mut bmp = Vec::with_capacity(total);
    bmp.extend_from_slice(b"BM");
    bmp.extend_from_slice(&(total as u32).to_le_bytes());
    bmp.extend_from_slice(&[0; 4]);
    bmp.extend_from_slice(&((offset + 14) as u32).to_le_bytes());
    bmp.extend_from_slice(dib);
    if header == 124 && bits == 32 && u32_at(52) == 0 {
        for pixel in bmp[offset + 14..end + 14].chunks_exact_mut(4) {
            pixel[3] = 255;
        }
    }
    Ok(bmp)
}

fn checked_rgba_size(width: usize, height: usize) -> Result<usize> {
    if width == 0 || height == 0 {
        return Err(invalid());
    }
    width
        .checked_mul(height)
        .and_then(|n| n.checked_mul(4))
        .filter(|n| *n <= MAX_IMAGE_BYTES)
        .ok_or_else(invalid)
}

struct Apartment;
impl Drop for Apartment {
    fn drop(&mut self) {
        // SAFETY: The converter initializes this apartment and releases all COM
        // interfaces before the guard is dropped, on the same worker thread.
        unsafe { CoUninitialize() };
    }
}

/// Convert a PNG or supported DIB to PNG. Existing PNG bytes are kept verbatim
/// after full pixel decoding validates the frame and its bounded dimensions.
pub fn to_png(bytes: &[u8], is_png: bool) -> Result<Vec<u8>> {
    if bytes.len() > MAX_IMAGE_BYTES || (is_png && !bytes.starts_with(PNG_SIGNATURE)) {
        return Err(invalid());
    }
    let bytes = if is_png {
        &bytes[..png_extent(bytes)?]
    } else {
        bytes
    };
    // SAFETY: This function is used on a windowless worker. Every successful
    // initialization, including S_FALSE, is balanced by this thread's guard.
    unsafe { CoInitializeEx(None, COINIT_MULTITHREADED).ok()? };
    let _apartment = Apartment;
    let bmp;
    let encoded = if is_png {
        bytes
    } else {
        bmp = dib_to_bmp(bytes)?;
        &bmp
    };
    // SAFETY: Input streams own their memory, output stream owns and frees its
    // HGLOBAL. Pixel buffers use checked sizes. All interfaces stay on this MTA.
    unsafe {
        let factory: IWICImagingFactory =
            CoCreateInstance(&CLSID_WICImagingFactory, None, CLSCTX_INPROC_SERVER)?;
        let input = SHCreateMemStream(Some(encoded)).ok_or_else(|| Error::from_hresult(E_FAIL))?;
        let decoder =
            factory.CreateDecoderFromStream(&input, null(), WICDecodeMetadataCacheOnLoad)?;
        if is_png && decoder.GetContainerFormat()? != GUID_ContainerFormatPng {
            return Err(invalid());
        }
        if decoder.GetFrameCount()? != 1 {
            return Err(invalid());
        }
        let source = decoder.GetFrame(0)?;
        let (mut width, mut height) = (0, 0);
        source.GetSize(&mut width, &mut height)?;
        let size = checked_rgba_size(width as usize, height as usize)?;
        let converter = factory.CreateFormatConverter()?;
        converter.Initialize(
            &source,
            &GUID_WICPixelFormat32bppBGRA,
            WICBitmapDitherTypeNone,
            None::<&IWICPalette>,
            0.0,
            WICBitmapPaletteTypeCustom,
        )?;
        if is_png {
            let mut pixels = vec![0; size];
            converter.CopyPixels(
                null(),
                width.checked_mul(4).ok_or_else(invalid)?,
                &mut pixels,
            )?;
            return Ok(bytes.to_vec());
        }
        let output = CreateStreamOnHGlobal(HGLOBAL::default(), true)?;
        let encoder = factory.CreateEncoder(&GUID_ContainerFormatPng, null())?;
        encoder.Initialize(&output, WICBitmapEncoderNoCache)?;
        let mut frame = None;
        encoder.CreateNewFrame(&mut frame, null_mut())?;
        let frame = frame.ok_or_else(|| Error::from_hresult(E_FAIL))?;
        frame.Initialize(None::<&windows::Win32::System::Com::StructuredStorage::IPropertyBag2>)?;
        frame.SetSize(width, height)?;
        let mut format = GUID_WICPixelFormat32bppBGRA;
        frame.SetPixelFormat(&mut format)?;
        if format != GUID_WICPixelFormat32bppBGRA {
            return Err(invalid());
        }
        frame.WriteSource(&converter, null())?;
        frame.Commit()?;
        encoder.Commit()?;
        let mut stat = STATSTG::default();
        output.Stat(&mut stat, STATFLAG_NONAME)?;
        let length = usize::try_from(stat.cbSize).map_err(|_| invalid())?;
        if length > MAX_IMAGE_BYTES {
            return Err(invalid());
        }
        output.Seek(0, STREAM_SEEK_SET, None)?;
        let mut result = vec![0; length];
        let mut read = 0;
        output
            .Read(result.as_mut_ptr().cast(), length as u32, Some(&mut read))
            .ok()?;
        if read as usize != length {
            return Err(invalid());
        }
        Ok(result)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn dib(height: i32) -> Vec<u8> {
        let mut data = vec![0; 48];
        data[0..4].copy_from_slice(&40u32.to_le_bytes());
        data[4..8].copy_from_slice(&1i32.to_le_bytes());
        data[8..12].copy_from_slice(&height.to_le_bytes());
        data[12..14].copy_from_slice(&1u16.to_le_bytes());
        data[14..16].copy_from_slice(&24u16.to_le_bytes());
        data[40..44].copy_from_slice(&[0, 0, 255, 0]);
        data[44..48].copy_from_slice(&[255, 0, 0, 0]);
        data
    }

    fn pixels(png: &[u8]) -> Vec<u8> {
        // SAFETY: Test-local COM interfaces stay on this thread. Pixel buffers
        // use checked sizes and every successful COM initialization is balanced.
        unsafe {
            CoInitializeEx(None, COINIT_MULTITHREADED).ok().unwrap();
            let _apartment = Apartment;
            let factory: IWICImagingFactory =
                CoCreateInstance(&CLSID_WICImagingFactory, None, CLSCTX_INPROC_SERVER).unwrap();
            let stream = SHCreateMemStream(Some(png)).unwrap();
            let decoder = factory
                .CreateDecoderFromStream(&stream, null(), WICDecodeMetadataCacheOnLoad)
                .unwrap();
            let frame = decoder.GetFrame(0).unwrap();
            let converter = factory.CreateFormatConverter().unwrap();
            converter
                .Initialize(
                    &frame,
                    &GUID_WICPixelFormat32bppBGRA,
                    WICBitmapDitherTypeNone,
                    None::<&IWICPalette>,
                    0.0,
                    WICBitmapPaletteTypeCustom,
                )
                .unwrap();
            let (mut width, mut height) = (0, 0);
            frame.GetSize(&mut width, &mut height).unwrap();
            let mut pixels = vec![0; checked_rgba_size(width as usize, height as usize).unwrap()];
            converter
                .CopyPixels(null(), width * 4, &mut pixels)
                .unwrap();
            pixels
        }
    }

    #[test]
    fn rejects_truncated_and_oversized_bitmaps_before_decoding() {
        assert!(dib_to_bmp(&dib(2)[..47]).is_err());
        let mut invalid = dib(2);
        invalid[4..8].copy_from_slice(&i32::MAX.to_le_bytes());
        assert!(dib_to_bmp(&invalid).is_err());
        assert!(checked_rgba_size(usize::MAX, 2).is_err());
        assert!(dib_to_bmp(&dib(i32::MIN)).is_err());
    }

    #[test]
    fn validates_png_and_rejects_non_png_content() {
        assert!(to_png(b"not an image", true).is_err());
        assert!(to_png(PNG_SIGNATURE, true).is_err());
        let encoded = to_png(&dib(2), false).unwrap();
        assert_eq!(to_png(&encoded, true).unwrap(), encoded);
        let mut padded = encoded.clone();
        padded.extend_from_slice(b"clipboard allocation padding");
        assert_eq!(to_png(&padded, true).unwrap(), encoded);
    }

    #[test]
    fn handles_top_down_and_bottom_up_without_resizing() {
        for height in [-2, 2] {
            let encoded = to_png(&dib(height), false).unwrap();
            assert!(encoded.starts_with(PNG_SIGNATURE));
            assert_eq!(u32::from_be_bytes(encoded[16..20].try_into().unwrap()), 1);
            assert_eq!(u32::from_be_bytes(encoded[20..24].try_into().unwrap()), 2);
            let red = [0, 0, 255, 255];
            let blue = [255, 0, 0, 255];
            let expected = if height < 0 {
                [red, blue].concat()
            } else {
                [blue, red].concat()
            };
            assert_eq!(pixels(&encoded), expected);
        }
    }

    #[test]
    fn v5_alpha_and_color_channels_survive_png_conversion() {
        let mut data = vec![0; 128];
        data[0..4].copy_from_slice(&124u32.to_le_bytes());
        data[4..8].copy_from_slice(&1i32.to_le_bytes());
        data[8..12].copy_from_slice(&(-1i32).to_le_bytes());
        data[12..14].copy_from_slice(&1u16.to_le_bytes());
        data[14..16].copy_from_slice(&32u16.to_le_bytes());
        data[16..20].copy_from_slice(&3u32.to_le_bytes());
        for (offset, mask) in [
            (40, 0x00ff0000u32),
            (44, 0x0000ff00),
            (48, 0x000000ff),
            (52, 0xff000000),
            (56, 0x73524742),
        ] {
            data[offset..offset + 4].copy_from_slice(&mask.to_le_bytes());
        }
        for alpha in [0, 127, 255] {
            let expected = [21, 73, 181, alpha];
            data[124..128].copy_from_slice(&expected);
            assert_eq!(pixels(&to_png(&data, false).unwrap()), expected);
        }
        data[52..56].copy_from_slice(&0u32.to_le_bytes());
        data[124..128].copy_from_slice(&[21, 73, 181, 0]);
        assert_eq!(pixels(&to_png(&data, false).unwrap()), [21, 73, 181, 255]);
    }
}
