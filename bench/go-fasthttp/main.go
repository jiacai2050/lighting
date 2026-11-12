package main

import (
	"bytes"
	"fmt"
	"log"
	"os"
	"time"

	"github.com/valyala/fasthttp"
)

var (
	strPing        = []byte("/ping")
	strEcho        = []byte("/echo")
	strUsersPrefix = []byte("/users/")
	strFilesPrefix = []byte("/files/")
	headerPlain    = []byte("text/plain; charset=utf-8")
	headerJSON     = []byte("application/json")
	echoPrefix     = []byte("Echo: ")
	newline        = []byte("\n")
)

func fastHandler(ctx *fasthttp.RequestCtx) {
	path := ctx.Path()
	switch {
	case ctx.IsGet() && bytes.Equal(path, strPing):
		ctx.SetContentTypeBytes(headerPlain)
		ctx.SetBodyString("pong\n")

	case ctx.IsGet() && bytes.HasPrefix(path, strUsersPrefix):
		id := path[len(strUsersPrefix):]
		ctx.SetContentTypeBytes(headerJSON)
		fmt.Fprintf(ctx, "{\"user_id\":\"%s\"}\n", id)

	case ctx.IsPost() && bytes.Equal(path, strEcho):
		ctx.SetContentTypeBytes(headerPlain)
		body := ctx.PostBody()
		w := ctx.Response.BodyWriter()
		w.Write(echoPrefix)
		w.Write(body)
		w.Write(newline)

	case ctx.IsGet() && bytes.HasPrefix(path, strFilesPrefix):
		filepath := path[len(strFilesPrefix):]
		ctx.SetContentTypeBytes(headerPlain)
		fmt.Fprintf(ctx, "Serving: %s\n", filepath)

	default:
		ctx.Error("Not Found", fasthttp.StatusNotFound)
	}
}

func main() {
	port := os.Getenv("PORT")
	if port == "" {
		port = "7000"
	}

	server := &fasthttp.Server{
		Handler:            fastHandler,
		Name:               "lighting-bench-fasthttp",
		ReadBufferSize:     8192,
		WriteBufferSize:    8192,
		// Timeout alignment note:
		// Unlike net/http, Zig, and actix-web which support dedicated header-only read timeouts
		// (ReadHeaderTimeout / client_request_timeout), fasthttp reads the entire request
		// (header + body) upfront into memory. Thus, ReadTimeout covers both header and body reading.
		ReadTimeout:        5 * time.Second,
		IdleTimeout:        120 * time.Second,
	}

	log.Printf("Go (fasthttp) server listening on http://127.0.0.1:%s...", port)
	if err := server.ListenAndServe(":" + port); err != nil {
		log.Fatalf("Server error: %v", err)
	}
}
