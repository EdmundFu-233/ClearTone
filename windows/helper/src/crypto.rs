use aes::{Aes128, Aes256};
use aes_gcm::{
    aead::{Aead, KeyInit as _},
    Aes128Gcm, Nonce,
};
use base64::{engine::general_purpose::STANDARD as B64, Engine as _};
use cipher::{block_padding::Pkcs7, BlockDecryptMut, BlockEncryptMut, KeyIvInit};
use hmac::{Hmac, Mac};
use md5::{Digest, Md5};
use num_bigint::BigUint;
use rand::{rngs::OsRng, RngCore};
use serde_json::Value;
use sha2::Sha256;
use x25519_dalek::{PublicKey, StaticSecret};

const EAPI_KEY: &[u8; 16] = b"e82ckenh8dichen8";
const STATIC_KEY: &str = "ab1d5a430f6bb04a3f01e81ddd72bd916d5ce591248ac128714806d7f8fb1b84";
const SIGN_KEY: &str =
    "mUHCwVNWJbunMqAHf5MImuirT6plvs6VSFW62MGHstFQxhBGdEoIhLItH3djc4+FB/OKty3+lL2rGeoFBpVe5g==";
// The RSA modulus in the upstream weapi public key (DER decoded).
const WEAPI_MODULUS: &str = "e0b509f6259df8642dbc35662901477df22677ec152b5ff68ace615bb7b725152b3ab17a876aea8a5aa76d2e417629ec4ee341f56135fccf695280104e0312ecbda92557c93870114af6c9d05c4f7f0c3685b7a46bee255932575cce10b424d813cfe4875d3e82047b97ddef52741d546b8e289dc6935b3ece0462db0a22b8e7";

pub fn eapi(uri: &str, payload: &Value) -> String {
    let text = payload.to_string();
    let digest = hex::encode(Md5::digest(format!("nobody{uri}use{text}md5forencrypt")));
    let plain = format!("{uri}-36cd479b6b5-{text}-36cd479b6b5-{digest}");
    hex::encode_upper(
        ecb::Encryptor::<Aes128>::new(EAPI_KEY.into())
            .encrypt_padded_vec_mut::<Pkcs7>(plain.as_bytes()),
    )
}

pub fn weapi(payload: &Value) -> Result<(String, String), String> {
    let alphabet = b"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
    let mut random = [0u8; 16];
    OsRng.fill_bytes(&mut random);
    let secret: String = random
        .iter()
        .map(|b| alphabet[(*b as usize) % alphabet.len()] as char)
        .collect();
    let iv = b"0102030405060708";
    let first = cbc::Encryptor::<Aes128>::new(b"0CoJUm6Qyw8W8jud".into(), iv.into())
        .encrypt_padded_vec_mut::<Pkcs7>(payload.to_string().as_bytes());
    let second = cbc::Encryptor::<Aes128>::new(secret.as_bytes().into(), iv.into())
        .encrypt_padded_vec_mut::<Pkcs7>(B64.encode(first).as_bytes());
    let modulus =
        BigUint::parse_bytes(WEAPI_MODULUS.as_bytes(), 16).ok_or("invalid weapi public key")?;
    let reversed: Vec<u8> = secret.bytes().rev().collect();
    let encrypted = BigUint::from_bytes_be(&reversed).modpow(&BigUint::from(65537u32), &modulus);
    Ok((B64.encode(second), format!("{encrypted:0256x}")))
}

pub fn aes_decrypt(data: &[u8], key: &[u8]) -> Result<Vec<u8>, String> {
    let mut input = data.to_vec();
    if key.len() == 16 {
        ecb::Decryptor::<Aes128>::new_from_slice(key)
            .map_err(|e| e.to_string())?
            .decrypt_padded_mut::<Pkcs7>(&mut input)
            .map(|x| x.to_vec())
            .map_err(|e| e.to_string())
    } else {
        ecb::Decryptor::<Aes256>::new_from_slice(key)
            .map_err(|e| e.to_string())?
            .decrypt_padded_mut::<Pkcs7>(&mut input)
            .map(|x| x.to_vec())
            .map_err(|e| e.to_string())
    }
}

fn aes_encrypt(data: &[u8], key: &[u8]) -> Vec<u8> {
    if key.len() == 16 {
        ecb::Encryptor::<Aes128>::new_from_slice(key)
            .expect("16 byte key")
            .encrypt_padded_vec_mut::<Pkcs7>(data)
    } else {
        ecb::Encryptor::<Aes256>::new_from_slice(key)
            .expect("32 byte key")
            .encrypt_padded_vec_mut::<Pkcs7>(data)
    }
}

fn mac(key: &[u8], data: &[u8]) -> Vec<u8> {
    let mut h = <Hmac<Sha256> as Mac>::new_from_slice(key).expect("HMAC accepts any key");
    h.update(data);
    h.finalize().into_bytes().to_vec()
}

pub fn signature(timestamp: &str, nonce: &str) -> String {
    B64.encode(mac(
        SIGN_KEY.as_bytes(),
        format!("{timestamp}{nonce}").as_bytes(),
    ))
}

pub fn decrypt_public_key(encoded: &str) -> Result<Value, String> {
    let bytes = B64.decode(encoded).map_err(|e| e.to_string())?;
    let key = hex::decode(STATIC_KEY).map_err(|e| e.to_string())?;
    serde_json::from_slice(&aes_decrypt(&bytes, &key)?).map_err(|e| e.to_string())
}

pub fn xeapi(
    uri: &str,
    payload: &Value,
    public_key: &Value,
) -> Result<Vec<(String, String)>, String> {
    let key = hex::decode(STATIC_KEY).map_err(|e| e.to_string())?;
    let body: String = url::form_urlencoded::Serializer::new(String::new())
        .extend_pairs(
            payload
                .as_object()
                .ok_or("xeapi payload must be an object")?
                .iter()
                .map(|(k, v)| {
                    (
                        k.as_str(),
                        v.as_str()
                            .map(str::to_owned)
                            .unwrap_or_else(|| v.to_string()),
                    )
                }),
        )
        .finish();
    let plain = serde_json::json!({"body": B64.encode(body), "queryString": "e_r=true"});
    let mut mask = [0u8; 16];
    let mut dynamic = [0u8; 16];
    OsRng.fill_bytes(&mut mask);
    OsRng.fill_bytes(&mut dynamic);
    let inner = aes_encrypt(plain.to_string().as_bytes(), &key);
    let xored: Vec<u8> = inner
        .iter()
        .enumerate()
        .map(|(i, b)| b ^ mask[i & 15])
        .collect();
    let b64 = B64.encode(xored);
    let rot = (mask[0] as usize & 15) % b64.len();
    let mut middle = mask.to_vec();
    middle.extend_from_slice(&b64.as_bytes()[rot..]);
    middle.extend_from_slice(&b64.as_bytes()[..rot]);
    let b = aes_encrypt(&middle, &dynamic);
    let peer = B64
        .decode(
            public_key["publicKey"]
                .as_str()
                .ok_or("missing publicKey")?,
        )
        .map_err(|e| e.to_string())?;
    let peer: [u8; 32] = peer.try_into().map_err(|_| "invalid publicKey length")?;
    let secret = StaticSecret::random_from_rng(OsRng);
    let ephemeral = PublicKey::from(&secret).to_bytes();
    let shared = secret.diffie_hellman(&PublicKey::from(peer));
    let prk = mac(&[0u8; 32], shared.as_bytes());
    let derived = mac(&prk, &[ephemeral.as_slice(), &[1]].concat());
    let mut nonce = [0u8; 12];
    OsRng.fill_bytes(&mut nonce);
    let s_plain = format!(
        "{}|android|{}",
        B64.encode(dynamic),
        public_key["sk"].as_str().unwrap_or("")
    );
    let sealed = Aes128Gcm::new_from_slice(&derived[..16])
        .map_err(|e| e.to_string())?
        .encrypt(Nonce::from_slice(&nonce), s_plain.as_bytes())
        .map_err(|e| e.to_string())?;
    let s = [ephemeral.as_slice(), nonce.as_slice(), sealed.as_slice()].concat();
    let r = aes_encrypt(
        format!(
            "{}|",
            public_key["version"].as_str().ok_or("missing version")?
        )
        .as_bytes(),
        &key,
    );
    let _ = uri; // encoded path is used by the HTTP transport, not the encrypted body
    Ok(vec![
        ("B".into(), B64.encode(b)),
        ("S".into(), B64.encode(s)),
        ("R".into(), B64.encode(r)),
    ])
}

pub fn decode_response(raw: Vec<u8>) -> Result<Vec<u8>, String> {
    if serde_json::from_slice::<Value>(&raw).is_ok() {
        return Ok(raw);
    }
    let decoded = aes_decrypt(&raw, EAPI_KEY)?;
    if decoded.starts_with(&[0x1f, 0x8b]) {
        use std::io::Read;
        let mut out = Vec::new();
        flate2::read::GzDecoder::new(decoded.as_slice())
            .take(8 * 1024 * 1024)
            .read_to_end(&mut out)
            .map_err(|e| e.to_string())?;
        Ok(out)
    } else {
        Ok(decoded)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn eapi_is_deterministic_and_order_sensitive() {
        let a: Value = serde_json::from_str(r#"{"a":1,"b":"2"}"#).unwrap();
        let b: Value = serde_json::from_str(r#"{"b":"2","a":1}"#).unwrap();
        assert_ne!(eapi("/api/test", &a), eapi("/api/test", &b));
        assert_eq!(eapi("/api/test", &a), eapi("/api/test", &a));
    }
    #[test]
    fn eapi_matches_upstream_node_vector() {
        let payload: Value = serde_json::from_str(r#"{"type":1111,"e_r":false,"header":{"osver":"10.15.7","deviceId":"p6i5y8e9w2s4h7g3","os":"osx","appver":"2.9.7","versioncode":"140","mobilename":"","buildver":"1789000000","resolution":"1920x1080","__csrf":"abc123","channel":"netease","requestId":"1789000000000_0042","MUSIC_U":"MUSIC_U_TEST"}}"#).unwrap();
        assert_eq!(eapi("/api/search/hot", &payload), "886AF8D09CBF98AE6DEE4A18C0124D90E49B69771D767F86360407771BFDD3C5CBC37FFB464977C270320FB311B703FC35BE63F93DB123A6E172F6E42701E4B8F90200DF8B889B6BE365EE0C268B7C5F744EAC137FBF448B596EBF81AA62FE2A293BCA03AB705694A2A227FD931DFC3A582EFB89D25D48BB12DC1031EF8626CA5554A4C791F0AD236697A8D85C627DBF3C22A55495DB727302CA58C0372D930F6B1F8C7C612D0C3D5FC7080F14DF8EAFE0BB87C3625C4B40F106AC3A9FDA3501BA30CA7FD02A5B33E3565F2B6DDA162281C7E94520F54F66A30BB631932B914C64E522FEECA4BDCBFF665D391F4023663E712D63B59FEED85F9DB27F8385DA49A4AF346E6297A796DDB0A5647ABC4AD6068B6E3A9DD8AD4D20504B21BD71DCC091A80053C0EAB2AB57805B57C93AD602B3B7450729DAA17652D242D18E8DDC465EEF4A69DCB79E93C1D2301D38DAC2651A9B5ADD84265760591BE248A8F37DB77053765B94655D8358A7628FCD75ECC5");
    }
}
