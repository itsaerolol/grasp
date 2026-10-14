//! TLS for the receiver. The server asks for a client certificate but doesn't require one, so stock
//! LocalSend senders without a cert still work, while Grasp's iPhone (which always presents one) can be
//! recognised. The cert is self-signed, so there is no chain to check; what we do check is the
//! handshake signature, which proves the sender holds the cert's private key. Its fingerprint is
//! then a sound identity for pairing.

use std::{io, sync::Arc};

use anyhow::{Context, Result};
use axum::Extension;
use axum_server::{accept::Accept, tls_rustls::RustlsAcceptor};
use futures_util::future::BoxFuture;
use rustls::{
    client::danger::HandshakeSignatureValid,
    crypto::CryptoProvider,
    pki_types::{CertificateDer, UnixTime},
    server::danger::{ClientCertVerified, ClientCertVerifier},
    DigitallySignedStruct, DistinguishedName, ServerConfig, SignatureScheme,
};
use tokio::io::{AsyncRead, AsyncWrite};
use tower::Layer;

use crate::cert::{fingerprint_of, Identity};

/// The client certificate fingerprint of the connection a request arrived on, if it presented one.
#[derive(Clone, Debug, Default)]
pub struct PeerCert(pub Option<String>);

#[derive(Debug)]
struct OptionalSelfSignedClientCert(Arc<CryptoProvider>);

impl ClientCertVerifier for OptionalSelfSignedClientCert {
    fn offer_client_auth(&self) -> bool {
        true
    }
    fn client_auth_mandatory(&self) -> bool {
        false
    }
    fn root_hint_subjects(&self) -> &[DistinguishedName] {
        &[]
    }
    fn verify_client_cert(
        &self,
        _end_entity: &CertificateDer<'_>,
        _intermediates: &[CertificateDer<'_>],
        _now: UnixTime,
    ) -> Result<ClientCertVerified, rustls::Error> {
        Ok(ClientCertVerified::assertion())
    }
    fn verify_tls12_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, rustls::Error> {
        rustls::crypto::verify_tls12_signature(message, cert, dss, &self.0.signature_verification_algorithms)
    }
    fn verify_tls13_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, rustls::Error> {
        rustls::crypto::verify_tls13_signature(message, cert, dss, &self.0.signature_verification_algorithms)
    }
    fn supported_verify_schemes(&self) -> Vec<SignatureScheme> {
        self.0.signature_verification_algorithms.supported_schemes()
    }
}

pub fn server_config(identity: &Identity) -> Result<ServerConfig> {
    let provider = Arc::new(rustls::crypto::ring::default_provider());
    let certs = rustls_pemfile::certs(&mut identity.cert_pem.as_bytes()).collect::<Result<Vec<_>, _>>()?;
    let key = rustls_pemfile::private_key(&mut identity.key_pem.as_bytes())?.context("key.pem contains no key")?;
    let mut cfg = ServerConfig::builder_with_provider(provider.clone())
        .with_safe_default_protocol_versions()?
        .with_client_cert_verifier(Arc::new(OptionalSelfSignedClientCert(provider)))
        .with_single_cert(certs, key)?;
    cfg.alpn_protocols = vec![b"h2".to_vec(), b"http/1.1".to_vec()];
    Ok(cfg)
}

/// Wraps the rustls acceptor and attaches the client cert fingerprint to every request on the connection.
#[derive(Clone)]
pub struct PeerCertAcceptor(pub RustlsAcceptor);

impl<I, S> Accept<I, S> for PeerCertAcceptor
where
    I: AsyncRead + AsyncWrite + Unpin + Send + 'static,
    S: Send + 'static,
{
    type Stream = tokio_rustls::server::TlsStream<I>;
    type Service = axum::middleware::AddExtension<S, PeerCert>;
    type Future = BoxFuture<'static, io::Result<(Self::Stream, Self::Service)>>;

    fn accept(&self, stream: I, service: S) -> Self::Future {
        let inner = self.0.clone();
        Box::pin(async move {
            let (tls, service) = inner.accept(stream, service).await?;
            let fp = tls.get_ref().1.peer_certificates().and_then(|c| c.first()).map(|c| fingerprint_of(c.as_ref()));
            Ok((tls, Extension(PeerCert(fp)).layer(service)))
        })
    }
}
