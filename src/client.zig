const std = @import("std");
const http = std.http;
const testing = std.testing;

const Allocator = std.mem.Allocator;

const MAX_RESPONSE_SIZE: usize = 3276800;

const PrefectError = error{
    BAD_REQUEST,
    NOT_FOUND,
    UNAUTHORIZED,
    UNKNOWN,
};

fn getErrorString(status: http.Status) ![]const u8 {
    return switch (status) {
        .bad_request => PrefectError.BAD_REQUEST,
        .not_found => PrefectError.NOT_FOUND,
        .unauthorized => PrefectError.UNAUTHORIZED,
        else => PrefectError.UNKNOWN,
    };
}

pub const PrefectClient = struct {
    api_url: []const u8,
    api_key: []const u8,
    alloc: Allocator = std.heap.page_allocator,
    headers: http.Headers,

    fn get_headers(alloc: std.mem.Allocator, api_key: []const u8) !http.Headers {
        var headers = http.Headers.init(alloc);
        try headers.append("Content-Type", "application/json");
        var auth_header = try std.fmt.allocPrint(alloc, "Bearer {s}", .{api_key});
        defer alloc.free(auth_header);
        try headers.append("Authorization", auth_header);
        return headers;
    }

    pub fn init(alloc: Allocator, api_key: ?[]const u8) !PrefectClient {
        const resolved_api_key = api_key orelse std.os.getenv("PREFECT_API_KEY").?;

        return PrefectClient{
            .api_url = std.os.getenv("PREFECT_API_URL").?,
            .api_key = resolved_api_key,
            .alloc = alloc,
            .headers = try PrefectClient.get_headers(alloc, resolved_api_key),
        };
    }

    pub fn deinit(self: *PrefectClient) void {
        self.headers.deinit();
    }

    fn request(self: *PrefectClient, path: []const u8, method: std.http.Method, body: ?[]const u8, params: ?std.json.Value) ![]const u8 {
        var http_client: std.http.Client = std.http.Client{
            .allocator = self.alloc,
        };
        defer http_client.deinit();

        var request_url = try std.fmt.allocPrint(self.alloc, "{s}{s}", .{ self.api_url, path });
        defer self.alloc.free(request_url);

        if (params) |p| {
            var params_str = std.ArrayList(u8).init(self.alloc);
            try std.json.stringify(p, .{}, params_str.writer());
            defer params_str.deinit();
            request_url = try std.fmt.allocPrint(self.alloc, "{s}?{s}", .{ request_url, params_str.items });
            defer self.alloc.free(request_url);
        }

        const uri = try std.Uri.parse(request_url);

        var req = try http_client.request(
            method,
            uri,
            self.headers,
            .{},
        );
        defer req.deinit();

        if (body) |b| {
            try req.writeAll(b);
        }

        try req.start();
        try req.wait();

        const status = req.response.status;

        if (status != .ok) {
            return getErrorString(status);
        }

        return try req.reader().readAllAlloc(self.alloc, MAX_RESPONSE_SIZE);
    }

    pub fn health(self: *PrefectClient) ![]const u8 {
        return self.request("/health", .GET, null, null);
    }
};

test "defaults are set" {
    const alloc = std.testing.allocator;

    var client = try PrefectClient.init(alloc, "pnu_api_key");
    defer client.deinit();

    try std.testing.expectEqual(client.api_key, "pnu_api_key");
    try std.testing.expectStringStartsWith(client.api_url, "https://api.");

    try std.testing.expect(std.mem.eql(u8, client.headers.getFirstValue("Content-Type").?, "application/json"));
    try std.testing.expect(std.mem.eql(u8, client.headers.getFirstValue("Authorization").?, "Bearer pnu_api_key"));
}

test "health" {
    const alloc = std.testing.allocator;

    var env = try std.process.getEnvMap(alloc);
    defer env.deinit();

    const api_key = env.get("PREFECT_API_KEY").?;

    var client = try PrefectClient.init(alloc, api_key);
    defer client.deinit();

    const response = try client.health();
    defer alloc.free(response);

    try std.testing.expectEqualStrings(response, "true");
}
