//! HTTP status code definitions conforming to RFC 9110 Section 15.

const std = @import("std");
const assert = std.debug.assert;

/// Status represents standard HTTP status codes.
pub const Status = enum(u16) {
    @"continue" = 100,
    switching_protocols = 101,

    ok = 200,
    created = 201,
    accepted = 202,
    no_content = 204,
    reset_content = 205,
    partial_content = 206,

    multiple_choices = 300,
    moved_permanently = 301,
    found = 302,
    see_other = 303,
    not_modified = 304,
    use_proxy = 305,
    temporary_redirect = 307,
    permanent_redirect = 308,

    bad_request = 400,
    unauthorized = 401,
    payment_required = 402,
    forbidden = 403,
    not_found = 404,
    method_not_allowed = 405,
    not_acceptable = 406,
    request_timeout = 408,
    conflict = 409,
    gone = 410,
    length_required = 411,
    payload_too_large = 413,
    uri_too_long = 414,
    unsupported_media_type = 415,
    range_not_satisfiable = 416,
    expectation_failed = 417,
    header_fields_too_large = 431,

    internal_server_error = 500,
    not_implemented = 501,
    bad_gateway = 502,
    service_unavailable = 503,
    gateway_timeout = 504,
    http_version_not_supported = 505,

    /// code returns the numeric integer value of the HTTP status code (e.g. 200).
    pub fn code(self: Status) u16 {
        return @backingInt(self);
    }

    /// phrase returns the standard RFC 9110 reason phrase for this status code (e.g. "OK", "Not Found").
    pub fn phrase(self: Status) []const u8 {
        return switch (self) {
            .@"continue" => "Continue",
            .switching_protocols => "Switching Protocols",

            .ok => "OK",
            .created => "Created",
            .accepted => "Accepted",
            .no_content => "No Content",
            .reset_content => "Reset Content",
            .partial_content => "Partial Content",

            .multiple_choices => "Multiple Choices",
            .moved_permanently => "Moved Permanently",
            .found => "Found",
            .see_other => "See Other",
            .not_modified => "Not Modified",
            .use_proxy => "Use Proxy",
            .temporary_redirect => "Temporary Redirect",
            .permanent_redirect => "Permanent Redirect",

            .bad_request => "Bad Request",
            .unauthorized => "Unauthorized",
            .payment_required => "Payment Required",
            .forbidden => "Forbidden",
            .not_found => "Not Found",
            .method_not_allowed => "Method Not Allowed",
            .not_acceptable => "Not Acceptable",
            .request_timeout => "Request Timeout",
            .conflict => "Conflict",
            .gone => "Gone",
            .length_required => "Length Required",
            .payload_too_large => "Payload Too Large",
            .uri_too_long => "URI Too Long",
            .unsupported_media_type => "Unsupported Media Type",
            .range_not_satisfiable => "Range Not Satisfiable",
            .expectation_failed => "Expectation Failed",
            .header_fields_too_large => "Request Header Fields Too Large",

            .internal_server_error => "Internal Server Error",
            .not_implemented => "Not Implemented",
            .bad_gateway => "Bad Gateway",
            .service_unavailable => "Service Unavailable",
            .gateway_timeout => "Gateway Timeout",
            .http_version_not_supported => "HTTP Version Not Supported",
        };
    }

    /// fromCode converts a numeric HTTP status code into a Status enum value, or null if unrecognized.
    pub fn fromCode(status_code: u16) ?Status {
        return std.enums.fromInt(Status, status_code);
    }
};

comptime {
    assert(@backingInt(Status.ok) == 200);
    assert(@backingInt(Status.not_found) == 404);
    assert(@backingInt(Status.internal_server_error) == 500);
}

test "Status phrase and code" {
    const s = Status.ok;
    try std.testing.expectEqual(@as(u16, 200), s.code());
    try std.testing.expectEqualStrings("OK", s.phrase());
}
