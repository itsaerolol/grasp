//! The notification chime, synthesized at startup so there is no audio asset to ship.
//! Two soft bell tones (E6 then B6) with a fast exponential decay, played through winmm.

use std::sync::OnceLock;

const RATE: u32 = 44_100;

fn bell(buf: &mut [f32], start_s: f32, freq: f32, gain: f32) {
    let start = (start_s * RATE as f32) as usize;
    for (i, out) in buf.iter_mut().enumerate().skip(start) {
        let t = (i - start) as f32 / RATE as f32;
        // Fundamental plus a quiet octave gives a glassy bell without harshness.
        let tone = (2.0 * std::f32::consts::PI * freq * t).sin() + 0.28 * (2.0 * std::f32::consts::PI * freq * 2.0 * t).sin();
        let attack = (t / 0.004).min(1.0); // 4 ms ramp: no click
        *out += tone * attack * (-t * 5.5).exp() * gain;
    }
}

fn wav() -> Vec<u8> {
    let mut samples = vec![0f32; (RATE as f32 * 1.1) as usize];
    bell(&mut samples, 0.00, 1318.5, 0.30);
    bell(&mut samples, 0.13, 1975.5, 0.26);

    let pcm: Vec<u8> = samples
        .iter()
        .flat_map(|s| ((s.clamp(-1.0, 1.0) * i16::MAX as f32) as i16).to_le_bytes())
        .collect();

    let mut out = Vec::with_capacity(44 + pcm.len());
    out.extend_from_slice(b"RIFF");
    out.extend_from_slice(&(36 + pcm.len() as u32).to_le_bytes());
    out.extend_from_slice(b"WAVEfmt ");
    out.extend_from_slice(&16u32.to_le_bytes()); // fmt chunk size
    out.extend_from_slice(&1u16.to_le_bytes()); // PCM
    out.extend_from_slice(&1u16.to_le_bytes()); // mono
    out.extend_from_slice(&RATE.to_le_bytes());
    out.extend_from_slice(&(RATE * 2).to_le_bytes()); // byte rate
    out.extend_from_slice(&2u16.to_le_bytes()); // block align
    out.extend_from_slice(&16u16.to_le_bytes()); // bits
    out.extend_from_slice(b"data");
    out.extend_from_slice(&(pcm.len() as u32).to_le_bytes());
    out.extend_from_slice(&pcm);
    out
}

#[cfg(windows)]
#[link(name = "winmm")]
extern "system" {
    fn PlaySoundW(sound: *const u8, module: isize, flags: u32) -> i32;
}

/// Fire and forget. The buffer lives in a static because SND_ASYNC keeps reading it after we return.
pub fn play() {
    #[cfg(windows)]
    {
        static WAV: OnceLock<Vec<u8>> = OnceLock::new();
        let data = WAV.get_or_init(wav);
        const SND_ASYNC: u32 = 0x0001;
        const SND_NODEFAULT: u32 = 0x0002;
        const SND_MEMORY: u32 = 0x0004;
        // SAFETY: `data` is a valid, 'static WAV image; SND_MEMORY treats the pointer as that image.
        unsafe {
            PlaySoundW(data.as_ptr(), 0, SND_MEMORY | SND_ASYNC | SND_NODEFAULT);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn wav_is_well_formed() {
        let w = wav();
        assert_eq!(&w[0..4], b"RIFF");
        assert_eq!(&w[8..12], b"WAVE");
        let data_len = u32::from_le_bytes(w[40..44].try_into().unwrap()) as usize;
        assert_eq!(w.len(), 44 + data_len);
        assert!(w[44..].chunks(2).any(|c| c != [0, 0]), "chime must not be silent");
    }
}
