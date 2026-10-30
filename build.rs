use std::{env, fs, path::Path};

// Rasterize the simple geometry in assets/laqay.svg into reproducible native
// icon resources. Four-by-four coverage samples keep the small edges smooth.
fn icon_image(size: u32, enabled: bool) -> Vec<u8> {
    let color = if enabled {
        [33u32, 102, 169]
    } else {
        [112, 116, 123]
    };
    let mut pixels = Vec::new();
    let mask_stride = size.div_ceil(32) * 4;
    let mut mask = vec![0u8; (mask_stride * size) as usize];
    for y in (0..size).rev() {
        for x in 0..size {
            let mut sum = [0u32; 4];
            for sy in 0..4 {
                for sx in 0..4 {
                    let px = (x as f64 + (sx as f64 + 0.5) / 4.0) * 32.0 / size as f64;
                    let py = (y as f64 + (sy as f64 + 0.5) / 4.0) * 32.0 / size as f64;
                    let cx = px.clamp(8.0, 24.0);
                    let cy = py.clamp(8.0, 24.0);
                    if (px - cx).powi(2) + (py - cy).powi(2) > 36.0 {
                        continue;
                    }
                    let paper = (10.0..23.0).contains(&px) && (7.0..25.0).contains(&py);
                    let letter = (13.0..16.0).contains(&px) && (11.0..22.0).contains(&py)
                        || (16.0..21.0).contains(&px) && (19.0..22.0).contains(&py);
                    let rgb = if paper && !letter { [255u32; 3] } else { color };
                    for channel in 0..3 {
                        sum[channel] += rgb[channel];
                    }
                    sum[3] += 255;
                }
            }
            let alpha = (sum[3] / 16) as u8;
            pixels.extend([
                (sum[2] / 16) as u8,
                (sum[1] / 16) as u8,
                (sum[0] / 16) as u8,
                alpha,
            ]);
            if alpha == 0 {
                mask[((size - 1 - y) * mask_stride + x / 8) as usize] |= 0x80 >> (x % 8);
            }
        }
    }
    let mut dib = Vec::new();
    for value in [40, size, size * 2] {
        dib.extend(value.to_le_bytes());
    }
    dib.extend(1u16.to_le_bytes());
    dib.extend(32u16.to_le_bytes());
    for value in [0, pixels.len() as u32, 0, 0, 0, 0] {
        dib.extend(value.to_le_bytes());
    }
    dib.extend(pixels);
    dib.extend(mask);
    dib
}

fn write_icon(path: &Path, enabled: bool) {
    let sizes = [16u32, 32];
    let images: Vec<_> = sizes
        .iter()
        .map(|size| icon_image(*size, enabled))
        .collect();
    let mut ico = vec![0, 0, 1, 0, 2, 0];
    let mut offset = 6 + sizes.len() as u32 * 16;
    for (size, image) in sizes.into_iter().zip(&images) {
        ico.extend([size as u8, size as u8, 0, 0]);
        ico.extend(1u16.to_le_bytes());
        ico.extend(32u16.to_le_bytes());
        ico.extend((image.len() as u32).to_le_bytes());
        ico.extend(offset.to_le_bytes());
        offset += image.len() as u32;
    }
    for image in images {
        ico.extend(image);
    }
    fs::write(path, ico).expect("write icon resource");
}

fn rc_path(path: &Path) -> String {
    path.to_string_lossy().replace('\\', "\\\\")
}

fn main() {
    println!("cargo:rerun-if-changed=assets/app.manifest");
    println!("cargo:rerun-if-changed=assets/laqay.svg");
    if env::var("CARGO_CFG_TARGET_OS").as_deref() != Ok("windows") {
        return;
    }
    let out = std::path::PathBuf::from(env::var_os("OUT_DIR").unwrap());
    let enabled = out.join("laqay.ico");
    let disabled = out.join("laqay-disabled.ico");
    write_icon(&enabled, true);
    write_icon(&disabled, false);
    let major = env::var("CARGO_PKG_VERSION_MAJOR").unwrap();
    let minor = env::var("CARGO_PKG_VERSION_MINOR").unwrap();
    let patch = env::var("CARGO_PKG_VERSION_PATCH").unwrap();
    let arch = match env::var("CARGO_CFG_TARGET_ARCH").unwrap().as_str() {
        "x86_64" => "amd64",
        "aarch64" => "arm64",
        _ => "x86",
    };
    let manifest = include_str!("assets/app.manifest")
        .replace("@VERSION@", &format!("{major}.{minor}.{patch}.0"))
        .replace("@ARCH@", arch);
    let manifest_path = out.join("laqay.manifest");
    fs::write(&manifest_path, manifest).expect("write application manifest");
    let resource = out.join("laqay.rc");
    fs::write(
        &resource,
        format!(
            "#pragma code_page(65001)\n1 ICON \"{}\"\n2 ICON \"{}\"\n1 24 \"{}\"\n",
            rc_path(&enabled),
            rc_path(&disabled),
            rc_path(&manifest_path)
        ),
    )
    .expect("write resource script");
    embed_resource::compile_for(resource, ["laqay"], embed_resource::NONE)
        .manifest_required()
        .expect("compile application resources");
}
