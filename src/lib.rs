//! Conservative policy for deciding whether clipboard data may be handled.

#[cfg(windows)]
pub mod explorer;

pub mod context;

#[cfg(windows)]
pub mod file_writer;

/// Available clipboard representations, determined at the time of a paste request.
#[derive(Debug, Default, Clone, Copy)]
pub struct ClipboardFormats {
    pub copied_files: bool,
    pub virtual_files: bool,
    pub ambiguous: bool,
    pub png: bool,
    pub dib_v5: bool,
    pub dib: bool,
    pub bitmap: bool,
}

#[derive(Debug, PartialEq, Eq)]
pub enum ImageFormat {
    Png,
    DibV5,
    Dib,
    Bitmap,
}

impl ClipboardFormats {
    /// File transfers and uncertain data always retain native paste behavior.
    pub fn preferred_image(self) -> Option<ImageFormat> {
        if self.copied_files || self.virtual_files || self.ambiguous {
            return None;
        }
        if self.png {
            Some(ImageFormat::Png)
        } else if self.dib_v5 {
            Some(ImageFormat::DibV5)
        } else if self.dib {
            Some(ImageFormat::Dib)
        } else if self.bitmap {
            Some(ImageFormat::Bitmap)
        } else {
            None
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn file_transfers_and_ambiguity_take_priority_over_every_image() {
        for (copied_files, virtual_files, ambiguous) in [
            (true, false, false),
            (false, true, false),
            (false, false, true),
        ] {
            let formats = ClipboardFormats {
                copied_files,
                virtual_files,
                ambiguous,
                png: true,
                dib_v5: true,
                dib: true,
                bitmap: true,
            };
            assert_eq!(formats.preferred_image(), None);
        }
    }

    #[test]
    fn image_priority_is_png_then_dib_v5_then_dib_then_bitmap() {
        let mut formats = ClipboardFormats {
            png: true,
            dib_v5: true,
            dib: true,
            bitmap: true,
            ..Default::default()
        };
        assert_eq!(formats.preferred_image(), Some(ImageFormat::Png));
        formats.png = false;
        assert_eq!(formats.preferred_image(), Some(ImageFormat::DibV5));
        formats.dib_v5 = false;
        assert_eq!(formats.preferred_image(), Some(ImageFormat::Dib));
        formats.dib = false;
        assert_eq!(formats.preferred_image(), Some(ImageFormat::Bitmap));
        formats.bitmap = false;
        assert_eq!(formats.preferred_image(), None);
    }
}
