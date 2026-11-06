use actix_web::{web, App, HttpResponse, HttpServer, Responder};
use std::env;

async fn ping() -> impl Responder {
    HttpResponse::Ok()
        .content_type("text/plain; charset=utf-8")
        .body("pong\n")
}

async fn user(path: web::Path<String>) -> impl Responder {
    let id = path.into_inner();
    HttpResponse::Ok()
        .content_type("application/json")
        .body(format!("{{\"user_id\":\"{}\"}}\n", id))
}

async fn echo(body: web::Bytes) -> impl Responder {
    let mut resp = Vec::with_capacity(7 + body.len() + 1);
    resp.extend_from_slice(b"Echo: ");
    resp.extend_from_slice(&body);
    resp.push(b'\n');
    HttpResponse::Ok()
        .content_type("text/plain; charset=utf-8")
        .body(resp)
}

async fn files(path: web::Path<String>) -> impl Responder {
    let filepath = path.into_inner();
    HttpResponse::Ok()
        .content_type("text/plain; charset=utf-8")
        .body(format!("Serving: {}\n", filepath))
}

#[actix_web::main]
async fn main() -> std::io::Result<()> {
    let port: u16 = env::var("PORT")
        .ok()
        .and_then(|p| p.parse().ok())
        .unwrap_or(7000);

    println!("Rust (actix-web) server listening on http://127.0.0.1:{}...", port);

    HttpServer::new(|| {
        App::new()
            .app_data(web::PayloadConfig::new(64 * 1024))
            .route("/ping", web::get().to(ping))
            .route("/users/{id}", web::get().to(user))
            .route("/echo", web::post().to(echo))
            .route("/files/{filepath:.*}", web::get().to(files))
    })
    .bind(("127.0.0.1", port))?
    .run()
    .await
}
