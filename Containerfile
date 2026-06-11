# ---- Build stage ----
FROM debian:trixie-slim AS build

ARG DEBIAN_FRONTEND=noninteractive

RUN apt update && apt upgrade -y \
  && apt install -y --no-install-recommends --no-install-suggests ca-certificates curl tar xz-utils minisign \
  && rm -rf "/var/lib/apt/lists/*" \
  && rm -rf /var/cache/apt/archives

# Install Zig
ARG ZIG_VERSION=0.16.0
ARG ZIG_SHA256=70e49664a74374b48b51e6f3fdfbf437f6395d42509050588bd49abe52ba3d00
RUN curl -fsSL -o /tmp/zig.tar.xz "https://ziglang.org/download/${ZIG_VERSION}/zig-x86_64-linux-${ZIG_VERSION}.tar.xz" \
  && echo "${ZIG_SHA256}  /tmp/zig.tar.xz" | sha256sum -c - \
  && tar -xJ -C /opt -f /tmp/zig.tar.xz \
  && rm /tmp/zig.tar.xz \
  && mv "/opt/zig-x86_64-linux-${ZIG_VERSION}" /opt/zig \
  && ln -s /opt/zig/zig /usr/local/bin/zig

WORKDIR /app

# build.zig.zon: fetch Horizon web framework
RUN cat > build.zig.zon <<'EOF'
.{
    .name = .hello_horizon,
    .version = "0.1.0",
    .fingerprint = 0xe072792d6c8ef880,
    .paths = .{""},
    .dependencies = .{
        .horizon = .{
            .url = "https://github.com/HARMONICOM/horizon/archive/refs/tags/v0.1.7.tar.gz",
        },
    },
}
EOF

# Let zig compute and save the correct dependency hash
RUN zig init \
  # && zig fetch --save=horizon "https://github.com/HARMONICOM/horizon/archive/refs/tags/v0.1.7.tar.gz"
  && zig fetch --save-exact=horizon https://github.com/HARMONICOM/horizon/archive/refs/tags/v0.1.7.tar.gz

# build.zig
RUN cat > build.zig <<'EOF'
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "hello_horizon",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const horizon = b.dependency("horizon", .{
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("horizon", horizon.module("horizon"));

    b.installArtifact(exe);
}
EOF

# src/main.zig: Hello world with optional "name" query parameter
RUN mkdir -p src && cat > src/main.zig <<'EOF'
const std = @import("std");
const horizon = @import("horizon");

fn extractNameParam(target: []const u8) ?[]const u8 {
    const q = std.mem.indexOfScalar(u8, target, '?') orelse return null;
    var it = std.mem.splitScalar(u8, target[q + 1 ..], '&');
    while (it.next()) |pair| {
        if (std.mem.startsWith(u8, pair, "name=")) {
            return pair[5..];
        }
    }
    return null;
}

fn handler(
    ctx: *horizon.Context,
    req: horizon.Request,
    res: *horizon.ResponseWriter,
) anyerror!void {
    _ = ctx;
    const name = extractNameParam(req.target) orelse "World";
    var buf: [256]u8 = undefined;
    const msg = try std.fmt.bufPrint(&buf, "Hello, {s}!\n", .{name});
    try res.any().writeAll(msg);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const addr = try std.net.Address.parseIp4("0.0.0.0", 8000);

    var server = try horizon.Server.init(allocator, .{
        .address = addr,
        .handler = horizon.Handler.init(handler),
    });
    defer server.deinit();

    std.log.info("Listening on http://0.0.0.0:8000 (use ?name=YourName)", .{});
    try server.serve();
}
EOF

RUN zig build run
RUN zig build -Doptimize=ReleaseSafe

# ---- Runtime stage ----
FROM debian:trixie-slim

ARG DEBIAN_FRONTEND=noninteractive

RUN apt update && apt upgrade -y \
  && apt install -y --no-install-recommends --no-install-suggests ca-certificates libgcc-s1 \
  && rm -rf "/var/lib/apt/lists/*" \
  && rm -rf /var/cache/apt/archives

WORKDIR /app

COPY --from=build /app/zig-out/bin/hello_horizon /usr/local/bin/hello_horizon

# Greeting name is provided per-request via the "name" query parameter, e.g.:
#   curl "http://localhost:8000/?name=Alice"

EXPOSE 8000

ENTRYPOINT ["/usr/local/bin/hello_horizon"]
