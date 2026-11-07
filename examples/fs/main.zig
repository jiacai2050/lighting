const std = @import("std");
const http = @import("lighting");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();

    const args = try init.minimal.args.toSlice(arena);

    if (args.len > 1 and (std.mem.eql(u8, args[1], "-h") or std.mem.eql(u8, args[1], "--help"))) {
        std.debug.print(
            \\Usage: fs [directory]
            \\
            \\A high-performance HTTP static file server.
            \\
            \\Arguments:
            \\  directory      Directory path to serve (default: current directory '.')
            \\
            \\Environment Variables:
            \\  PORT           HTTP port to listen on (default: 7000)
            \\  ROOT_DIR       Directory to serve if not specified via CLI
            \\
        , .{});
        return;
    }

    const port: u16 = if (init.environ_map.get("PORT")) |p|
        std.fmt.parseInt(u16, p, 10) catch 7000
    else
        7000;

    const root_dir = if (args.len > 1)
        args[1]
    else if (init.environ_map.get("ROOT_DIR")) |r|
        r
    else
        ".";

    var fs = http.extra.fs.FileServer.init(allocator, .{
        .root_dir = root_dir,
        .auto_index = true,
        .show_hidden = false,
    });

    var mux = http.ServeMux.init(allocator);
    defer mux.deinit();

    // Route all paths to the FileServer
    try mux.handle("/", fs.handler());

    var logging = http.LoggingHandler{ .next = mux.handler() };

    var server = http.Server.init(allocator, io, .{
        .handler = logging.handler(),
    });

    std.log.info("File server serving '{s}' on http://127.0.0.1:{d}...", .{ root_dir, port });
    try server.listenAndServe("127.0.0.1", port);
}
