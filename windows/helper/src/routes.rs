use serde_json::{json, Value};
use std::collections::HashMap;

pub type Query = HashMap<String, String>;

#[derive(Clone, Copy, PartialEq, Eq)]
pub enum Crypto {
    Eapi,
    Weapi,
    Xeapi,
}

pub struct Endpoint {
    pub uri: String,
    pub crypto: Crypto,
    pub data: Value,
}

fn thread_id(q: &Query) -> Result<String, String> {
    let prefix = match get(q, "type") {
        "0" => "R_SO_4_",
        "1" => "R_MV_5_",
        "2" => "A_PL_0_",
        "3" => "R_AL_3_",
        "4" => "A_DJ_1_",
        "5" => "R_VI_62_",
        "6" => "A_EV_2_",
        "7" => "A_DR_14_",
        _ => return Err("invalid resource type".into()),
    };
    Ok(format!("{prefix}{}", required_id(q, "id")?))
}

fn get<'a>(q: &'a Query, name: &str) -> &'a str {
    q.get(name).map(String::as_str).unwrap_or("")
}
fn default<'a>(q: &'a Query, name: &str, fallback: &'a str) -> &'a str {
    let value = get(q, name);
    if value.is_empty() {
        fallback
    } else {
        value
    }
}
fn param(q: &Query, name: &str) -> Value {
    q.get(name).map(|s| json!(s)).unwrap_or(Value::Null)
}
fn number(q: &Query, name: &str, fallback: i64) -> Value {
    if let Some(value) = q.get(name).filter(|v| !v.is_empty()) {
        json!(value)
    } else {
        json!(fallback)
    }
}
fn required_id(q: &Query, name: &str) -> Result<String, String> {
    let id = get(q, name);
    if id.is_empty() || !id.bytes().all(|c| c.is_ascii_digit()) || id.len() > 20 {
        return Err(format!("invalid {name}"));
    }
    Ok(id.to_owned())
}

pub fn endpoint(route: &str, q: &Query) -> Result<Endpoint, String> {
    use Crypto::*;
    let (uri, crypto, data) = match route {
        "/login/qr/key" => ("/api/login/qrcode/unikey".into(), Eapi, json!({"type":3})),
        "/login/qr/check" => (
            "/api/login/qrcode/client/login".into(),
            Eapi,
            json!({"key":param(q,"key"),"type":3}),
        ),
        "/logout" => ("/api/logout".into(), Eapi, json!({})),
        "/user/account" => ("/api/nuser/account/get".into(), Weapi, json!({})),
        "/cloudsearch" => (
            "/api/cloudsearch/pc".into(),
            Eapi,
            json!({"s":param(q,"keywords"),"type":number(q,"type",1),"limit":number(q,"limit",30),"offset":number(q,"offset",0),"total":true}),
        ),
        "/search/suggest" => (
            format!(
                "/api/search/suggest/{}",
                if get(q, "type") == "mobile" {
                    "keyword"
                } else {
                    "web"
                }
            ),
            Weapi,
            json!({"s":get(q,"keywords")}),
        ),
        "/search/hot" => ("/api/search/hot".into(), Eapi, json!({"type":1111})),
        "/search/hot/detail" => ("/api/hotsearchlist/get".into(), Weapi, json!({})),
        "/playlist/detail" | "/playlist/track/all" => (
            "/api/v6/playlist/detail".into(),
            Eapi,
            json!({"id":param(q,"id"),"n":100000,"s":number(q,"s",8)}),
        ),
        "/song/detail" => {
            let ids = get(q, "ids").split(',').map(str::trim).collect::<Vec<_>>();
            if ids.is_empty()
                || ids.len() > 1000
                || ids
                    .iter()
                    .any(|id| id.parse::<u64>().ok().filter(|id| *id > 0).is_none())
            {
                return Err("invalid song ids".into());
            }
            let c = format!(
                "[{}]",
                ids.iter()
                    .map(|id| format!("{{\"id\":{id}}}"))
                    .collect::<Vec<_>>()
                    .join(",")
            );
            ("/api/v3/song/detail".into(), Weapi, json!({"c":c}))
        }
        "/album" => (
            format!("/api/v1/album/{}", required_id(q, "id")?),
            Weapi,
            json!({}),
        ),
        "/artist/detail" => (
            "/api/artist/head/info/get".into(),
            Eapi,
            json!({"id":param(q,"id")}),
        ),
        "/artist/top/song" => (
            "/api/artist/top/song".into(),
            Weapi,
            json!({"id":param(q,"id")}),
        ),
        "/artist/album" => (
            format!("/api/artist/albums/{}", required_id(q, "id")?),
            Weapi,
            json!({"limit":number(q,"limit",30),"offset":number(q,"offset",0),"total":true}),
        ),
        "/artist/songs" => (
            "/api/v1/artist/songs".into(),
            Eapi,
            json!({"id":param(q,"id"),"private_cloud":"true","work_type":1,"order":default(q,"order","hot"),"offset":number(q,"offset",0),"limit":number(q,"limit",100)}),
        ),
        "/artist/mv" => (
            "/api/artist/mvs".into(),
            Weapi,
            json!({"artistId":param(q,"id"),"limit":param(q,"limit"),"offset":param(q,"offset"),"total":true}),
        ),
        "/artist/desc" => (
            "/api/artist/introduction".into(),
            Weapi,
            json!({"id":param(q,"id")}),
        ),
        "/simi/artist" => (
            "/api/discovery/simiArtist".into(),
            Weapi,
            json!({"artistid":param(q,"id")}),
        ),
        "/song/url/v1" => (
            "/api/song/enhance/player/url/v1".into(),
            Xeapi,
            json!({"ids":format!("[{}]",required_id(q,"id")?),"level":param(q,"level"),"encodeType":"flac"}),
        ),
        "/lyric/new" => (
            "/api/song/lyric/v1".into(),
            Eapi,
            json!({"id":param(q,"id"),"cp":false,"tv":0,"lv":0,"rv":0,"kv":0,"yv":0,"ytv":0,"yrv":0}),
        ),
        "/user/playlist" => (
            "/api/user/playlist".into(),
            Weapi,
            json!({"uid":param(q,"uid"),"limit":number(q,"limit",30),"offset":number(q,"offset",0),"includeVideo":true}),
        ),
        "/likelist" => (
            "/api/song/like/get".into(),
            Eapi,
            json!({"uid":param(q,"uid")}),
        ),
        "/song/like" => (
            "/api/song/like".into(),
            Eapi,
            json!({"trackId":param(q,"id"),"userid":param(q,"uid"),"like":get(q,"like")!="false"}),
        ),
        "/personalized" => (
            "/api/personalized/playlist".into(),
            Weapi,
            json!({"limit":number(q,"limit",30),"total":true,"n":1000}),
        ),
        "/recommend/songs" => (
            "/api/v3/discovery/recommend/songs".into(),
            Weapi,
            json!({"afresh":param(q,"afresh")}),
        ),
        "/recommend/resource" => (
            "/api/v1/discovery/recommend/resource".into(),
            Weapi,
            json!({}),
        ),
        "/dj/catelist" => ("/api/djradio/category/get".into(), Weapi, json!({})),
        "/dj/recommend" => ("/api/djradio/recommend/v1".into(), Weapi, json!({})),
        "/dj/hot" => (
            "/api/djradio/hot/v1".into(),
            Weapi,
            json!({"limit":number(q,"limit",30),"offset":number(q,"offset",0)}),
        ),
        "/dj/program" => (
            "/api/dj/program/byradio".into(),
            Weapi,
            json!({"radioId":param(q,"rid"),"limit":number(q,"limit",30),"offset":number(q,"offset",0),"asc":get(q,"asc")=="true"}),
        ),
        "/dj/detail" => (
            "/api/djradio/v2/get".into(),
            Weapi,
            json!({"id":param(q,"rid")}),
        ),
        "/dj/sublist" => (
            "/api/djradio/get/subed".into(),
            Weapi,
            json!({"limit":number(q,"limit",30),"offset":number(q,"offset",0),"total":true}),
        ),
        "/toplist" => ("/api/toplist".into(), Eapi, json!({})),
        "/top/song" => (
            "/api/v1/discovery/new/songs".into(),
            Weapi,
            json!({"areaId":number(q,"type",0),"total":true}),
        ),
        "/top/playlist" => (
            "/api/playlist/list".into(),
            Weapi,
            json!({"cat":default(q,"cat","全部"),"order":default(q,"order","hot"),"limit":number(q,"limit",50),"offset":number(q,"offset",0),"total":true}),
        ),
        "/simi/song" => (
            "/api/v1/discovery/simiSong".into(),
            Weapi,
            json!({"songid":param(q,"id"),"limit":number(q,"limit",50),"offset":number(q,"offset",0)}),
        ),
        "/playlist/create" => (
            "/api/playlist/create".into(),
            Weapi,
            json!({"name":param(q,"name"),"privacy":default(q,"privacy","0"),"type":default(q,"type","NORMAL")}),
        ),
        "/playlist/delete" => (
            "/api/playlist/remove".into(),
            Weapi,
            json!({"ids":format!("[{}]",required_id(q,"id")?)}),
        ),
        "/playlist/name/update" => (
            "/api/playlist/update/name".into(),
            Eapi,
            json!({"id":param(q,"id"),"name":param(q,"name")}),
        ),
        "/album/sub" => (
            format!(
                "/api/album/{}",
                if get(q, "t") == "1" { "sub" } else { "unsub" }
            ),
            Weapi,
            json!({"id":param(q,"id")}),
        ),
        "/artist/sub" => (
            format!(
                "/api/artist/{}",
                if get(q, "t") == "1" { "sub" } else { "unsub" }
            ),
            Weapi,
            json!({"artistId":param(q,"id"),"artistIds":format!("[{}]",required_id(q,"id")?)}),
        ),
        "/dj/sub" => (
            format!(
                "/api/djradio/{}",
                if get(q, "t") == "1" { "sub" } else { "unsub" }
            ),
            Weapi,
            json!({"id":param(q,"rid")}),
        ),
        "/album/sublist" => (
            "/api/album/sublist".into(),
            Weapi,
            json!({"limit":number(q,"limit",25),"offset":number(q,"offset",0),"total":true}),
        ),
        "/artist/sublist" => (
            "/api/artist/sublist".into(),
            Weapi,
            json!({"limit":number(q,"limit",25),"offset":number(q,"offset",0),"total":true}),
        ),
        "/playlist/tracks" => (
            "/api/playlist/manipulate/tracks".into(),
            Eapi,
            json!({"op":param(q,"op"),"pid":param(q,"pid"),"trackIds":serde_json::to_string(&get(q,"tracks").split(',').collect::<Vec<_>>()).unwrap(),"imme":"true"}),
        ),
        "/comment/new" => {
            let page = get(q, "pageNo").parse::<i64>().unwrap_or(1).max(1);
            let size = get(q, "pageSize")
                .parse::<i64>()
                .unwrap_or(20)
                .clamp(1, 100);
            let sort = match get(q, "sortType").parse::<i64>().unwrap_or(99) {
                1 => 99,
                n => n,
            };
            let cursor = match sort {
                99 => ((page - 1) * size).to_string(),
                2 => format!("normalHot#{}", (page - 1) * size),
                3 => default(q, "cursor", "0").to_owned(),
                _ => String::new(),
            };
            (
                "/api/v2/resource/comments".into(),
                Eapi,
                json!({"threadId":thread_id(q)?,"pageNo":page,"showInner":true,"pageSize":size,"cursor":cursor,"sortType":sort}),
            )
        }
        "/comment/like" => (
            format!(
                "/api/v1/comment/{}",
                if get(q, "t") == "1" { "like" } else { "unlike" }
            ),
            Weapi,
            json!({"threadId":thread_id(q)?,"commentId":param(q,"cid")}),
        ),
        "/msg/notices" => (
            "/api/msg/notices".into(),
            Weapi,
            json!({"limit":number(q,"limit",30),"time":number(q,"lasttime",-1)}),
        ),
        "/msg/private" => (
            "/api/msg/private/users".into(),
            Weapi,
            json!({"offset":number(q,"offset",0),"limit":number(q,"limit",30),"total":"true"}),
        ),
        "/msg/comments" => (
            format!("/api/v1/user/comments/{}", required_id(q, "uid")?),
            Weapi,
            json!({"beforeTime":default(q,"before","-1"),"limit":number(q,"limit",30),"total":"true","uid":param(q,"uid")}),
        ),
        "/user/record" => (
            "/api/v1/play/record".into(),
            Weapi,
            json!({"uid":param(q,"uid"),"type":number(q,"type",0)}),
        ),
        "/daily_signin" => (
            "/api/point/dailyTask".into(),
            Eapi,
            json!({"type":number(q,"type",0)}),
        ),
        "/recommend/songs/dislike" => (
            "/api/v2/discovery/recommend/dislike".into(),
            Weapi,
            json!({"resId":param(q,"id"),"resType":4,"sceneType":1}),
        ),
        _ => return Err(format!("unsupported route: {route}")),
    };
    Ok(Endpoint { uri, crypto, data })
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn translates_search_and_rejects_unknown_routes() {
        let q = Query::from([("keywords".into(), "hello".into())]);
        let e = endpoint("/cloudsearch", &q).unwrap();
        assert_eq!(e.uri, "/api/cloudsearch/pc");
        assert_eq!(
            e.data.to_string(),
            r#"{"s":"hello","type":1,"limit":30,"offset":0,"total":true}"#
        );
        assert!(endpoint("/unrecognized", &q).is_err());
        assert!(endpoint("/album", &Query::from([("id".into(), "../bad".into())])).is_err());
    }
}
