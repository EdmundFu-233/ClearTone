mod crypto;
mod routes;

use axum::{
    extract::{Query, State},
    http::{HeaderMap, StatusCode},
    routing::get,
    Json, Router,
};
use base64::{engine::general_purpose::STANDARD as B64, Engine as _};
use rand::{rngs::OsRng, RngCore};
use routes::{Crypto, Endpoint};
use serde_json::{json, Value};
use std::{collections::HashMap, sync::Arc, time::Duration};

struct App {
    token: String,
    client: reqwest::Client,
    device_id: String,
    public_key: tokio::sync::Mutex<Option<Value>>,
    anonymous: tokio::sync::Mutex<Option<String>>,
}

type Reply = (StatusCode, Json<Value>);
fn fail(status: StatusCode, message: &str) -> Reply {
    (
        status,
        Json(json!({"code":status.as_u16(),"message":message})),
    )
}
fn now_ms() -> u128 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis()
}

fn cookies(raw: &str) -> HashMap<String, String> {
    let mut result = HashMap::new();
    for part in raw.split(';') {
        if let Some((k, v)) = part.trim().split_once('=') {
            if ![
                "path", "domain", "expires", "max-age", "httponly", "secure", "samesite",
            ]
            .contains(&k.to_lowercase().as_str())
            {
                result.insert(k.trim().to_owned(), v.trim().to_owned());
            }
        }
    }
    result
}

fn format_cookies(jar: &HashMap<String, String>) -> String {
    let mut pairs: Vec<_> = jar.iter().collect();
    pairs.sort_by_key(|(k, _)| *k);
    pairs
        .iter()
        .map(|(k, v)| format!("{k}={v}"))
        .collect::<Vec<_>>()
        .join("; ")
}

fn device_id() -> String {
    let path = std::env::var_os("LOCALAPPDATA")
        .map(std::path::PathBuf::from)
        .unwrap_or_else(std::env::temp_dir)
        .join("ClearTone")
        .join("rust-helper-device-id");
    if let Ok(id) = std::fs::read_to_string(&path) {
        if id.len() == 32 && id.bytes().all(|b| b.is_ascii_hexdigit()) {
            return id;
        }
    }
    let mut raw = [0u8; 16];
    OsRng.fill_bytes(&mut raw);
    let id = hex::encode(raw);
    if let Some(parent) = path.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    let _ = std::fs::write(path, &id);
    id
}

fn form(pairs: &[(String, String)]) -> String {
    url::form_urlencoded::Serializer::new(String::new())
        .extend_pairs(pairs.iter().map(|(k, v)| (k.as_str(), v.as_str())))
        .finish()
}

impl App {
    async fn anonymous_token(&self) -> Option<String> {
        let mut saved = self.anonymous.lock().await;
        if let Some(value) = saved.as_ref() {
            return Some(value.clone());
        }
        use md5::{Digest, Md5};
        let mask = b"3go8&$8*3*3h0k(2)2";
        let encoded: Vec<u8> = self
            .device_id
            .bytes()
            .enumerate()
            .map(|(i, b)| b ^ mask[i % mask.len()])
            .collect();
        let username = B64.encode(format!(
            "{} {}",
            self.device_id,
            B64.encode(Md5::digest(encoded))
        ));
        let endpoint = Endpoint {
            uri: "/api/register/anonimous".into(),
            crypto: Crypto::Xeapi,
            data: json!({"username":username}),
        };
        match Box::pin(self.upstream(endpoint, "")).await {
            Ok((_, cookies)) => {
                let token = cookies
                    .iter()
                    .flat_map(|c| c.split(';'))
                    .find_map(|p| p.trim().strip_prefix("MUSIC_A="))
                    .map(str::to_owned);
                if let Some(token) = token.as_ref() {
                    *saved = Some(token.clone());
                }
                token
            }
            Err(_) => None,
        }
    }

    async fn key(&self) -> Result<Value, String> {
        let mut saved = self.public_key.lock().await;
        if let Some(key) = saved.as_ref() {
            return Ok(key.clone());
        }
        let timestamp = now_ms().to_string();
        let mut random = [0u8; 16];
        OsRng.fill_bytes(&mut random);
        let nonce: String = random.iter().map(|b| (b % 10 + b'0') as char).collect();
        let fields = vec![
            ("appVersion".into(), "9.5.61".into()),
            ("currentKeyVersion".into(), "".into()),
            ("deviceId".into(), self.device_id.clone()),
            ("nonce".into(), nonce.clone()),
            ("os".into(), "android".into()),
            ("requestType".into(), "active".into()),
            ("signature".into(), crypto::signature(&timestamp, &nonce)),
            ("t1".into(), "".into()),
            ("t2".into(), "".into()),
            ("timestamp".into(), timestamp),
            ("uid".into(), "".into()),
        ];
        let response: Value = self
            .client
            .post("https://interface.music.163.com/api/gorilla/anti/crawler/security/key/get")
            .header("User-Agent", ANDROID_UA)
            .header("Cookie", format!("deviceId={}", self.device_id))
            .header("Content-Type", "application/x-www-form-urlencoded")
            .body(form(&fields))
            .send()
            .await
            .map_err(|e| e.to_string())?
            .error_for_status()
            .map_err(|e| e.to_string())?
            .json()
            .await
            .map_err(|e| e.to_string())?;
        let data = &response["data"];
        let encrypted = data["encryptedData"].as_str().ok_or("missing public key")?;
        let ts = data["timestamp"]
            .as_i64()
            .map(|n| n.to_string())
            .ok_or("missing timestamp")?;
        if data["signature"].as_str() != Some(crypto::signature(&ts, &nonce).as_str()) {
            return Err("invalid key signature".into());
        }
        let key = crypto::decrypt_public_key(encrypted)?;
        if key["sk"].as_str().unwrap_or("").is_empty() {
            return Err("invalid key".into());
        }
        *saved = Some(key.clone());
        Ok(key)
    }

    async fn upstream(
        &self,
        mut endpoint: Endpoint,
        cookie: &str,
    ) -> Result<(Value, Vec<String>), String> {
        let mut jar = cookies(cookie);
        if endpoint.uri != "/api/register/anonimous"
            && !jar.contains_key("MUSIC_U")
            && !jar.contains_key("MUSIC_A")
        {
            if let Some(token) = self.anonymous_token().await {
                jar.insert("MUSIC_A".into(), token);
            }
        }
        let csrf = jar.get("__csrf").cloned().unwrap_or_default();
        jar.entry("deviceId".into())
            .or_insert_with(|| self.device_id.clone());
        let os = jar.get("os").cloned().unwrap_or_else(|| "pc".into());
        let fields: Vec<(String, String)>;
        let mut request;
        let now = now_ms();
        let build = (now / 1000).to_string();
        match endpoint.crypto {
            Crypto::Weapi => {
                let data = endpoint.data.as_object_mut().ok_or("invalid data")?;
                data.retain(|_, v| !v.is_null());
                data.insert("e_r".into(), json!(false));
                data.insert("csrf_token".into(), json!(csrf));
                let (params, sec) = crypto::weapi(&endpoint.data)?;
                fields = vec![("params".into(), params), ("encSecKey".into(), sec)];
                request = self
                    .client
                    .post(format!(
                        "https://music.163.com/weapi/{}",
                        endpoint.uri.trim_start_matches("/api/")
                    ))
                    .header("Referer", "https://music.163.com")
                    .header("User-Agent", WEB_UA)
                    .header("Cookie", format_cookies(&jar));
            }
            Crypto::Eapi => {
                let request_id = format!("{now}_{:04}", rand::random::<u16>() % 1000);
                let mut header = json!({
                    "osver": jar.get("osver").cloned().unwrap_or_else(|| "Microsoft-Windows-10-Professional-build-19045-64bit".into()),
                    "deviceId": jar["deviceId"], "os": os,
                    "appver": jar.get("appver").cloned().unwrap_or_else(|| "3.1.17.204416".into()),
                    "versioncode": jar.get("versioncode").cloned().unwrap_or_else(|| "140".into()),
                    "mobilename": "", "buildver": build, "resolution": "1920x1080",
                    "__csrf": csrf, "channel": jar.get("channel").cloned().unwrap_or_else(|| "netease".into()),
                    "requestId": request_id,
                });
                for name in ["MUSIC_U", "MUSIC_A", "NMTID"] {
                    if let Some(v) = jar.get(name) {
                        header[name] = json!(v);
                    }
                }
                let header_cookie = header
                    .as_object()
                    .unwrap()
                    .iter()
                    .map(|(k, v)| (k.clone(), v.as_str().unwrap_or("").to_string()))
                    .collect::<Vec<_>>();
                let data = endpoint.data.as_object_mut().ok_or("invalid data")?;
                data.retain(|_, v| !v.is_null());
                data.insert("e_r".into(), json!(false));
                data.insert("header".into(), header);
                fields = vec![("params".into(), crypto::eapi(&endpoint.uri, &endpoint.data))];
                request = self
                    .client
                    .post(format!(
                        "https://interfacepc.music.163.com/eapi/{}",
                        endpoint.uri.trim_start_matches("/api/")
                    ))
                    .header("User-Agent", PC_UA)
                    .header(
                        "Cookie",
                        form(&header_cookie).replace('+', "%20").replace('&', "; "),
                    );
            }
            Crypto::Xeapi => {
                let key = self.key().await?;
                jar.insert("os".into(), "android".into());
                jar.insert("osver".into(), "16".into());
                jar.insert("appver".into(), "9.1.65".into());
                jar.insert("buildver".into(), build.clone());
                jar.insert("deviceId".into(), self.device_id.clone());
                jar.insert("sDeviceId".into(), self.device_id.clone());
                fields = crypto::xeapi(&endpoint.uri, &endpoint.data, &key)?;
                request = self
                    .client
                    .post(format!(
                        "https://interface3.music.163.com/xeapi/{}",
                        endpoint.uri.trim_start_matches("/api/")
                    ))
                    .header("User-Agent", ANDROID_UA)
                    .header("Cookie", format_cookies(&jar))
                    .header("X-Client-Enc-State", "ENCRYPTED")
                    .header("x-aeapi", "true")
                    .header("x-deviceid", &self.device_id)
                    .header("x-sdeviceid", &self.device_id)
                    .header("x-os", "android")
                    .header("x-osver", "16")
                    .header("x-appver", "9.1.65")
                    .header("x-buildver", build);
                if let Some(music_u) = jar.get("MUSIC_U") {
                    request = request.header("x-music-u", music_u);
                }
            }
        }
        let response = request
            .header(
                "Content-Type",
                "application/x-www-form-urlencoded;charset=utf-8",
            )
            .body(form(&fields))
            .send()
            .await
            .map_err(|e| e.to_string())?;
        let status = response.status();
        let set_cookies = response
            .headers()
            .get_all("set-cookie")
            .iter()
            .filter_map(|v| v.to_str().ok().map(str::to_owned))
            .collect::<Vec<_>>();
        let raw = response.bytes().await.map_err(|e| e.to_string())?.to_vec();
        if !status.is_success() {
            return Err(format!("upstream HTTP {status}"));
        }
        let raw = if endpoint.crypto == Crypto::Xeapi {
            crypto::decode_response(raw)?
        } else {
            raw
        };
        let body = serde_json::from_slice::<Value>(&raw)
            .map_err(|_| "invalid upstream response".to_owned())?;
        Ok((body, set_cookies))
    }
}

const PC_UA: &str = "Mozilla/5.0 (Windows NT 10.0; WOW64) AppleWebKit/537.36 (KHTML, like Gecko) Safari/537.36 Chrome/91.0.4472.164 NeteaseMusicDesktop/3.1.29.205117";
const WEB_UA: &str = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36 Edg/124.0.0.0";
const ANDROID_UA: &str = "NeteaseMusic/9.5.61.260802021928(9005061);Dalvik/2.1.0 (Linux; U; Android 12; HBN-AL00 Build/cd737a2.0)";

async fn health(State(app): State<Arc<App>>, headers: HeaderMap) -> Reply {
    if !authorized(&app, &headers) {
        return fail(StatusCode::UNAUTHORIZED, "unauthorized");
    }
    (StatusCode::OK, Json(json!({"code":200,"status":"ok"})))
}

fn authorized(app: &App, headers: &HeaderMap) -> bool {
    headers.get("x-ct-token").and_then(|v| v.to_str().ok()) == Some(app.token.as_str())
}

async fn api(
    State(app): State<Arc<App>>,
    axum::extract::Path(path): axum::extract::Path<String>,
    Query(query): Query<routes::Query>,
    headers: HeaderMap,
) -> Reply {
    if !authorized(&app, &headers) {
        return fail(StatusCode::UNAUTHORIZED, "unauthorized");
    }
    let route = format!("/{path}");
    if route == "/login/qr/create" {
        let key = query.get("key").map(String::as_str).unwrap_or("");
        if key.is_empty() || key.len() > 256 {
            return fail(StatusCode::BAD_REQUEST, "invalid key");
        }
        let qrurl = format!(
            "https://music.163.com/login?codekey={}",
            url::form_urlencoded::byte_serialize(key.as_bytes()).collect::<String>()
        );
        let qrimg = if query.get("qrimg").map(String::as_str) == Some("true") {
            match qr_data_url(&qrurl) {
                Ok(img) => img,
                Err(_) => return fail(StatusCode::INTERNAL_SERVER_ERROR, "QR generation failed"),
            }
        } else {
            String::new()
        };
        return (
            StatusCode::OK,
            Json(json!({"code":200,"data":{"qrurl":qrurl,"qrimg":qrimg}})),
        );
    }
    let endpoint = match routes::endpoint(&route, &query) {
        Ok(e) => e,
        Err(e) => {
            return fail(
                if e.starts_with("unsupported") {
                    StatusCode::NOT_FOUND
                } else {
                    StatusCode::BAD_REQUEST
                },
                &e,
            )
        }
    };
    let cookie = headers
        .get("x-ct-cookie")
        .and_then(|h| h.to_str().ok())
        .unwrap_or("");
    let response = if route == "/playlist/track/all" {
        match app.upstream(endpoint, cookie).await {
            Ok((body, _)) => {
                let ids = body["playlist"]["trackIds"]
                    .as_array()
                    .cloned()
                    .unwrap_or_default();
                let offset = query
                    .get("offset")
                    .and_then(|s| s.parse::<usize>().ok())
                    .unwrap_or(0)
                    .min(ids.len());
                let limit = query
                    .get("limit")
                    .and_then(|s| s.parse::<usize>().ok())
                    .filter(|v| *v > 0)
                    .unwrap_or(1000)
                    .min(1000);
                let selected: Vec<_> = ids
                    .iter()
                    .skip(offset)
                    .take(limit)
                    .map(|v| json!({"id":v["id"]}))
                    .collect();
                app.upstream(
                    Endpoint {
                        uri: "/api/v3/song/detail".into(),
                        crypto: Crypto::Eapi,
                        data: json!({"c":Value::Array(selected).to_string()}),
                    },
                    cookie,
                )
                .await
            }
            Err(e) => Err(e),
        }
    } else {
        app.upstream(endpoint, cookie).await
    };
    match response {
        Ok((mut body, cookies)) => {
            if route == "/login/qr/key" {
                body = json!({"data":body,"code":200});
            }
            if route == "/login/qr/check" {
                if let Some(obj) = body.as_object_mut() {
                    obj.insert(
                        "cookie".into(),
                        json!(cookies
                            .iter()
                            .map(|c| c.split(';').next().unwrap_or(""))
                            .collect::<Vec<_>>()
                            .join(";")),
                    );
                }
            }
            (StatusCode::OK, Json(body))
        }
        Err(e) => {
            eprintln!("helper {}: {}", route, e);
            fail(StatusCode::BAD_GATEWAY, "upstream request failed")
        }
    }
}

fn qr_data_url(url: &str) -> Result<String, String> {
    use image::{DynamicImage, GrayImage, ImageFormat, Luma};
    let code = qrcode::QrCode::new(url.as_bytes()).map_err(|e| e.to_string())?;
    let size = code.width() as u32;
    let mut image = GrayImage::from_pixel((size + 8) * 5, (size + 8) * 5, Luma([255]));
    for y in 0..size {
        for x in 0..size {
            let color = if code[(x as usize, y as usize)] == qrcode::Color::Dark {
                0
            } else {
                255
            };
            for dy in 0..5 {
                for dx in 0..5 {
                    image.put_pixel((x + 4) * 5 + dx, (y + 4) * 5 + dy, Luma([color]));
                }
            }
        }
    }
    let mut png = std::io::Cursor::new(Vec::new());
    DynamicImage::ImageLuma8(image)
        .write_to(&mut png, ImageFormat::Png)
        .map_err(|e| e.to_string())?;
    Ok(format!(
        "data:image/png;base64,{}",
        B64.encode(png.into_inner())
    ))
}

#[cfg(windows)]
fn watch_parent(pid: u32) {
    use windows_sys::Win32::Foundation::{CloseHandle, WAIT_OBJECT_0};
    use windows_sys::Win32::System::Threading::{
        OpenProcess, WaitForSingleObject, PROCESS_SYNCHRONIZE,
    };
    std::thread::spawn(move || unsafe {
        let handle = OpenProcess(PROCESS_SYNCHRONIZE, 0, pid);
        if !handle.is_null() {
            if WaitForSingleObject(handle, u32::MAX) == WAIT_OBJECT_0 {
                std::process::exit(0);
            }
            CloseHandle(handle);
        }
    });
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let token = std::env::var("CT_AUTH_TOKEN").map_err(|_| "CT_AUTH_TOKEN is required")?;
    if token.is_empty() {
        return Err("CT_AUTH_TOKEN must not be empty".into());
    }
    let port: u16 = std::env::var("PORT")?.parse()?;
    #[cfg(windows)]
    if let Ok(pid) = std::env::var("CT_PARENT_PID")
        .and_then(|s| s.parse().map_err(|_| std::env::VarError::NotPresent))
    {
        watch_parent(pid);
    }
    let client = reqwest::Client::builder()
        .timeout(Duration::from_secs(20))
        .no_proxy()
        .build()?;
    let app = Arc::new(App {
        token,
        client,
        device_id: device_id(),
        public_key: tokio::sync::Mutex::new(None),
        anonymous: tokio::sync::Mutex::new(None),
    });
    let router = Router::new()
        .route("/ct_health", get(health))
        .route("/*path", get(api).post(api))
        .with_state(app);
    let listener = tokio::net::TcpListener::bind((std::net::Ipv4Addr::LOCALHOST, port)).await?;
    axum::serve(listener, router).await?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn cookies_drop_attributes() {
        let jar = cookies("MUSIC_U=abc==; Path=/; HttpOnly; os=pc");
        assert_eq!(jar["MUSIC_U"], "abc==");
        assert!(!jar.contains_key("Path"));
    }
    #[test]
    fn qr_is_a_png_data_url() {
        assert!(qr_data_url("https://music.163.com/login?codekey=test")
            .unwrap()
            .starts_with("data:image/png;base64,"));
    }
}
