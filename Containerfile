# syntax=docker/dockerfile:1.6

# ---- Build stage ----
FROM debian:trixie-slim AS build

# Install Zig
ARG ZIG_VERSION=0.13.0
RUN apt-get update \
    && apt-get install -y --no-install-recommends curl tar xz-utils ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && curl -fsSL "https://ziglang.org/download/${ZIG_VERSION}/zig-linux-x86_64-${ZIG_VERSION}.tar.xz" \
       | tar -xJ -C /opt \
    && ln -s "/opt/zig-linux-x86_64-${ZIG_VERSION}/zig" /usr/local/bin/zig

WORKDIR /app

# build.zig.zon: fetch Horizon web framework
RUN cat > build.zig.zon <<'EOF'
.{
    .name = "hello_horizon",
    .version = "0.1.0",
    .paths = .{""},
    .dependencies = .{
        .horizon = .{
            .url = "https://github.com/HARMONICOM/horizon/archive/refs/tags/v0.1.7.tar.gz",
            .hash = "a830e571b9b3c84d379bb9e6c51a6923175d323aeb4e2038cd7a023952ab3499",
        },
    },
}
EOF

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

# src/main.zig: Hello world with optional NAME env var
RUN mkdir -p src && cat > src/main.zig <<'EOF'
const std = @import("std");
const horizon = @import("horizon");

var greet_name: []const u8 = "World";

fn handler(
    ctx: *horizon.Context,
    req: horizon.Request,
    res: *horizon.ResponseWriter,
) anyerror!void {
    _ = ctx;
    _ = req;
    var buf: [256]u8 = undefined;
    const msg = try std.fmt.bufPrint(&buf, "Hello, {s}!\n", .{greet_name});
    try res.any().writeAll(msg);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    if (std.process.getEnvVarOwned(allocator, "NAME")) |n| {
        greet_name = n;
    } else |_| {
        greet_name = "World";
    }

    const addr = try std.net.Address.parseIp4("0.0.0.0", 8000);

    var server = try horizon.Server.init(allocator, .{
        .address = addr,
        .handler = horizon.Handler.init(handler),
    });
    defer server.deinit();

    std.log.info("Listening on http://0.0.0.0:8000 (greeting: {s})", .{greet_name});
    try server.serve();
}
EOF

RUN zig build -Doptimize=ReleaseSafe

# ---- Runtime stage ----
FROM debian:trixie-slim
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates libgcc-s1 \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY --from=build /app/zig-out/bin/hello_horizon /usr/local/bin/hello_horizon

# NAME parameter: replaces "World" in greeting when set
ARG NAME=World
ENV NAME=${NAME}

EXPOSE 8000
ENTRYPOINT ["/usr/local/bin/hello_horizon"]
