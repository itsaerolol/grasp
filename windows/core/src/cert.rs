use std::path::Path;

use anyhow::{Context, Result};
use rcgen::{date_time_ymd, CertificateParams, DnType, KeyPair};
use sha2::{Digest, Sha256};

/// The receiver's TLS identity. LocalSend peers identify each other by the SHA-256 of the
/// certificate DER (uppercase hex), so the cert is generated once and persisted: a new cert
/// would make every paired phone report "PC identity changed".
pub struct Identity {
    pub cert_pem: String,
    pub key_pem: String,
    pub fingerprint: String,
}

pub fn fingerprint_of(der: &[u8]) -> String {
    hex::encode_upper(Sha256::digest(der))
}

pub fn load_or_create(dir: &Path) -> Result<Identity> {
    std::fs::create_dir_all(dir).with_context(|| format!("creating {}", dir.display()))?;
    let cert_path = dir.join("cert.pem");
    let key_path = dir.join("key.pem");

    if !(cert_path.exists() && key_path.exists()) {
        let key = KeyPair::generate()?;
        let mut params = CertificateParams::new(vec!["grasp".to_string()])?;
        params.distinguished_name.push(DnType::CommonName, "Grasp");
        params.not_before = date_time_ymd(2020, 1, 1);
        params.not_after = date_time_ymd(2099, 1, 1);
        let cert = params.self_signed(&key)?;
        std::fs::write(&cert_path, cert.pem())?;
        std::fs::write(&key_path, key.serialize_pem())?;
    }

    let cert_pem = std::fs::read_to_string(&cert_path)?;
    let key_pem = std::fs::read_to_string(&key_path)?;
    let der = rustls_pemfile::certs(&mut cert_pem.as_bytes())
        .next()
        .context("cert.pem contains no certificate")??;
    Ok(Identity { fingerprint: fingerprint_of(der.as_ref()), cert_pem, key_pem })
}
