use anyhow::{ensure, Context, Result};
use narad_core::{
    identity::{Identity, SignedFrame},
    model::Peer,
    MAX_FRAME,
};
use rustls::{
    client::danger::{HandshakeSignatureValid, ServerCertVerified, ServerCertVerifier},
    pki_types::{CertificateDer, PrivateKeyDer, PrivatePkcs8KeyDer, ServerName, UnixTime},
    DigitallySignedStruct, SignatureScheme,
};
use serde::{de::DeserializeOwned, Serialize};
use std::{collections::HashMap, sync::Arc, time::Duration};
use tokio::{
    io::{AsyncBufReadExt, AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt},
    net::TcpStream,
};
use tokio_rustls::{TlsAcceptor, TlsConnector};

pub const LOCAL_MAX_FRAME: usize = 512 * 1024;

pub async fn read_frame<R: AsyncRead + Unpin, T: DeserializeOwned>(stream: &mut R) -> Result<T> {
    read_frame_limit(stream, MAX_FRAME).await
}
pub async fn read_frame_limit<R: AsyncRead + Unpin, T: DeserializeOwned>(
    stream: &mut R,
    limit: usize,
) -> Result<T> {
    let mut data = Vec::new();
    let mut reader = tokio::io::BufReader::new(stream).take((limit + 2) as u64);
    reader.read_until(b'\n', &mut data).await?;
    ensure!(data.len() <= limit + 1, "message too large");
    ensure!(data.last() == Some(&b'\n'), "truncated message");
    data.pop();
    Ok(serde_json::from_slice(&data)?)
}
pub async fn write_frame<W: AsyncWrite + Unpin, T: Serialize>(
    stream: &mut W,
    value: &T,
) -> Result<()> {
    write_frame_limit(stream, value, MAX_FRAME).await
}
pub async fn write_frame_limit<W: AsyncWrite + Unpin, T: Serialize>(
    stream: &mut W,
    value: &T,
    limit: usize,
) -> Result<()> {
    let data = serde_json::to_vec(value)?;
    ensure!(data.len() <= limit, "message too large");
    stream.write_all(&data).await?;
    stream.write_all(b"\n").await?;
    stream.flush().await?;
    Ok(())
}

#[derive(Debug)]
struct PinnedCertificate {
    hash: String,
}
impl ServerCertVerifier for PinnedCertificate {
    fn verify_server_cert(
        &self,
        end: &CertificateDer<'_>,
        _intermediates: &[CertificateDer<'_>],
        _name: &ServerName<'_>,
        _ocsp: &[u8],
        _now: UnixTime,
    ) -> std::result::Result<ServerCertVerified, rustls::Error> {
        if blake3::hash(end.as_ref()).to_hex().as_str() != self.hash {
            return Err(rustls::Error::General(
                "peer certificate does not match pairing pin".into(),
            ));
        }
        Ok(ServerCertVerified::assertion())
    }
    fn verify_tls12_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        signature: &DigitallySignedStruct,
    ) -> std::result::Result<HandshakeSignatureValid, rustls::Error> {
        rustls::crypto::verify_tls12_signature(
            message,
            cert,
            signature,
            &rustls::crypto::ring::default_provider().signature_verification_algorithms,
        )
    }
    fn verify_tls13_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        signature: &DigitallySignedStruct,
    ) -> std::result::Result<HandshakeSignatureValid, rustls::Error> {
        rustls::crypto::verify_tls13_signature(
            message,
            cert,
            signature,
            &rustls::crypto::ring::default_provider().signature_verification_algorithms,
        )
    }
    fn supported_verify_schemes(&self) -> Vec<SignatureScheme> {
        rustls::crypto::ring::default_provider()
            .signature_verification_algorithms
            .supported_schemes()
    }
}
pub fn acceptor(identity: &Identity) -> Result<TlsAcceptor> {
    let cfg = rustls::ServerConfig::builder()
        .with_no_client_auth()
        .with_single_cert(
            vec![CertificateDer::from(identity.certificate.clone())],
            PrivateKeyDer::Pkcs8(PrivatePkcs8KeyDer::from(identity.tls_key.clone())),
        )?;
    Ok(TlsAcceptor::from(Arc::new(cfg)))
}
pub async fn remote_call(
    identity: &Identity,
    own: &Peer,
    peer: &Peer,
    file_plane: bool,
    payload: serde_json::Value,
) -> Result<serde_json::Value> {
    peer.validate()?;
    let config = rustls::ClientConfig::builder()
        .dangerous()
        .with_custom_certificate_verifier(Arc::new(PinnedCertificate {
            hash: peer.certificate_hash.clone(),
        }))
        .with_no_client_auth();
    let request = identity.sign(own, payload)?;
    let response = tokio::time::timeout(Duration::from_secs(15), async {
        let socket = TcpStream::connect((peer.address.as_str(), peer.port + u16::from(file_plane)))
            .await
            .context("device unreachable")?;
        let mut tls = TlsConnector::from(Arc::new(config))
            .connect(ServerName::try_from("narad.local")?, socket)
            .await?;
        write_frame(&mut tls, &request).await?;
        let response: SignedFrame = read_frame(&mut tls).await?;
        response.verify(&mut HashMap::new())?;
        ensure!(
            response.sender.public_key == peer.public_key
                && response.sender.certificate_hash == peer.certificate_hash,
            "response identity mismatch"
        );
        ensure!(
            response.payload["reply_to"] == request.request_id,
            "response request mismatch"
        );
        let result = response.payload["result"].clone();
        if result["ok"] == false {
            anyhow::bail!(
                "{}",
                result["error"].as_str().unwrap_or("peer rejected request")
            );
        }
        Ok(result)
    })
    .await
    .context("peer request timed out")??;
    Ok(response)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[tokio::test]
    async fn bounded_frames_reject_oversized_input() {
        let (mut a, mut b) = tokio::io::duplex(MAX_FRAME + 2);
        let writer = tokio::spawn(async move {
            a.write_all(&vec![b'x'; MAX_FRAME + 1]).await.unwrap();
        });
        assert!(read_frame::<_, serde_json::Value>(&mut b).await.is_err());
        writer.await.unwrap();
    }
}
