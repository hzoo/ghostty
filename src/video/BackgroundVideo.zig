const std = @import("std");
const builtin = @import("builtin");
const Surface = @import("../Surface.zig");
const internal_os = @import("../os/main.zig");

const Allocator = std.mem.Allocator;
const log = std.log.scoped(.background_video);

const video_cache_max_bytes: u64 = 2 * 1024 * 1024 * 1024; // 2 GiB
const video_cache_ttl_ns: i128 = 30 * 24 * std.time.ns_per_hour; // 30 days

pub const BackgroundVideo = struct {
    alloc: Allocator,
    surface: *Surface,
    audio_enabled: bool = true,

    thread: ?std.Thread = null,
    stop_flag: std.atomic.Value(bool) = .init(false),
    dropped_frames: std.atomic.Value(u64) = .init(0),
    accept_frames: std.atomic.Value(bool) = .init(false),
    render_enabled: std.atomic.Value(bool) = .init(false),
    paused: std.atomic.Value(bool) = .init(false),
    seek_enabled: std.atomic.Value(bool) = .init(false),
    stop_thread: ?std.Thread = null,
    stop_thread_done: std.atomic.Value(bool) = .init(false),

    child_mutex: std.Thread.Mutex = .{},
    child: ?*std.process.Child = null,
    audio_child: ?*std.process.Child = null,
    resolve_child: ?*std.process.Child = null,
    audio_ipc_path: ?[]u8 = null,
    session_mutex: std.Thread.Mutex = .{},
    session: BackgroundMediaSession = .{},

    const Provider = enum {
        youtube,
        soundcloud,
        direct_media,
        generic_url,
    };

    const Metadata = struct {
        title: ?[]u8 = null,
        artist: ?[]u8 = null,
        album: ?[]u8 = null,

        fn deinit(self: *Metadata, alloc: Allocator) void {
            if (self.title) |v| alloc.free(v);
            if (self.artist) |v| alloc.free(v);
            if (self.album) |v| alloc.free(v);
            self.* = .{};
        }
    };

    const MetadataStatus = enum {
        unresolved,
        resolved,
    };

    const Track = struct {
        url: []u8,
        provider: Provider,
        metadata_status: MetadataStatus = .unresolved,
        metadata: Metadata = .{},

        fn deinit(self: *Track, alloc: Allocator) void {
            self.metadata.deinit(alloc);
            alloc.free(self.url);
            self.* = undefined;
        }
    };

    const BackgroundMediaSession = struct {
        tracks: std.ArrayListUnmanaged(Track) = .empty,
        index: usize = 0,

        fn deinit(self: *BackgroundMediaSession, alloc: Allocator) void {
            self.clear(alloc);
            self.tracks.deinit(alloc);
        }

        fn clear(self: *BackgroundMediaSession, alloc: Allocator) void {
            for (self.tracks.items) |*track| track.deinit(alloc);
            self.tracks.clearRetainingCapacity();
            self.index = 0;
        }

        fn setFromInput(self: *BackgroundMediaSession, alloc: Allocator, raw: []const u8) !void {
            self.clear(alloc);

            var it = std.mem.splitScalar(u8, raw, ',');
            while (it.next()) |part| {
                const url = std.mem.trim(u8, part, " \t\r\n");
                if (url.len == 0) continue;

                try self.tracks.append(alloc, .{
                    .url = try alloc.dupe(u8, url),
                    .provider = providerFromUrl(url),
                });
            }

            if (self.tracks.items.len == 0) {
                return error.EmptyQueue;
            }
            self.index = 0;
        }
    };

    pub fn init(alloc: Allocator, surface: *Surface) BackgroundVideo {
        return .{
            .alloc = alloc,
            .surface = surface,
        };
    }

    pub fn deinit(self: *BackgroundVideo) void {
        self.joinStopThread();
        self.stopInternal(true);
        self.clearAudioIpcPath();
        self.session_mutex.lock();
        self.session.deinit(self.alloc);
        self.session_mutex.unlock();
    }

    pub fn droppedFrameCount(self: *const BackgroundVideo) u64 {
        return self.dropped_frames.load(.monotonic);
    }

    pub fn setUrl(self: *BackgroundVideo, url: []const u8) !void {
        self.joinStopThread();

        if (url.len == 0) {
            self.stopInternal(true);
            self.session_mutex.lock();
            self.session.clear(self.alloc);
            self.session_mutex.unlock();
            return;
        }

        self.session_mutex.lock();
        const set_res = self.session.setFromInput(self.alloc, url);
        self.session_mutex.unlock();
        try set_res;

        self.restart(false);
    }

    pub fn stop(self: *BackgroundVideo, clear: bool) void {
        self.joinStopThread();
        self.stopInternal(clear);
    }

    pub fn hasActivePlayback(self: *const BackgroundVideo) bool {
        return self.accept_frames.load(.acquire);
    }

    pub fn isPaused(self: *const BackgroundVideo) bool {
        return self.paused.load(.acquire);
    }

    pub fn isSeekSupported(self: *const BackgroundVideo) bool {
        return self.seek_enabled.load(.acquire);
    }

    pub fn setPaused(self: *BackgroundVideo, paused: bool) bool {
        self.child_mutex.lock();
        defer self.child_mutex.unlock();

        if (!self.accept_frames.load(.acquire)) return false;

        var any: bool = false;
        if (self.child) |child| {
            self.signalPause(child, paused);
            any = true;
        }
        if (self.audio_child) |child| {
            self.signalPause(child, paused);
            any = true;
        }

        if (any) self.paused.store(paused, .release);
        return any;
    }

    pub fn seekRelative(self: *BackgroundVideo, seconds: i32) bool {
        if (seconds == 0) return false;
        if (!self.seek_enabled.load(.acquire)) return false;
        return self.sendMpvIpcSeek(seconds);
    }

    pub fn backgroundMediaQueueCount(self: *BackgroundVideo) u32 {
        self.session_mutex.lock();
        defer self.session_mutex.unlock();
        return @intCast(self.session.tracks.items.len);
    }

    /// Returns zero-based queue index, or -1 when there is no active track.
    pub fn backgroundMediaQueueIndex(self: *BackgroundVideo) i32 {
        self.session_mutex.lock();
        defer self.session_mutex.unlock();
        if (self.session.tracks.items.len == 0) return -1;
        return @intCast(self.session.index);
    }

    pub fn dupCurrentMetadataTitle(self: *BackgroundVideo) ?[]u8 {
        return self.dupCurrentMetadataField(.title);
    }

    pub fn dupCurrentMetadataArtist(self: *BackgroundVideo) ?[]u8 {
        return self.dupCurrentMetadataField(.artist);
    }

    pub fn dupCurrentTrackUrl(self: *BackgroundVideo) ?[]u8 {
        self.session_mutex.lock();
        defer self.session_mutex.unlock();
        const track = self.currentTrackLocked() orelse return null;
        return self.alloc.dupe(u8, track.url) catch null;
    }

    pub fn nextTrack(self: *BackgroundVideo) bool {
        return self.rotateTrack(1);
    }

    pub fn previousTrack(self: *BackgroundVideo) bool {
        return self.rotateTrack(-1);
    }

    pub fn clearFrame(self: *BackgroundVideo) void {
        self.render_enabled.store(false, .release);
        self.sendClear();
    }

    /// Toggle whether decoded frames are rendered while playback continues.
    /// Returns true when toggled, false when playback isn't active.
    pub fn toggleVisibility(self: *BackgroundVideo) bool {
        if (!self.accept_frames.load(.acquire)) return false;

        const show = !self.render_enabled.load(.acquire);
        self.render_enabled.store(show, .release);

        if (!show) {
            self.sendClear();
            return true;
        }

        // We rely on the next decoded frame for visible content.
        self.surface.renderer_thread.wakeup.notify() catch {};
        return true;
    }

    pub fn clearAsync(self: *BackgroundVideo) void {
        log.info("background video stop requested", .{});

        // Clear visual output immediately, then stop decode/audio in the
        // background without blocking UI interaction.
        self.accept_frames.store(false, .release);
        self.render_enabled.store(false, .release);
        self.paused.store(false, .release);
        self.seek_enabled.store(false, .release);
        self.sendClear();

        // Stop child processes immediately so audio/video halt right away.
        // We intentionally avoid any waits/joins on this caller thread.
        self.stop_flag.store(true, .seq_cst);
        self.killChildren();
    }

    fn joinStopThread(self: *BackgroundVideo) void {
        if (self.stop_thread) |thr| {
            thr.join();
            self.stop_thread = null;
            self.stop_thread_done.store(false, .release);
        }
    }

    fn stopInternal(self: *BackgroundVideo, clear: bool) void {
        self.accept_frames.store(false, .release);
        self.render_enabled.store(false, .release);
        self.paused.store(false, .release);
        self.seek_enabled.store(false, .release);
        self.stop_flag.store(true, .seq_cst);
        self.killChildren();
        self.stopAudio();
        self.clearAudioIpcPath();

        if (self.thread) |thr| {
            thr.join();
            self.thread = null;
        }

        self.stop_flag.store(false, .seq_cst);

        if (clear) self.sendClear();
    }

    fn restart(self: *BackgroundVideo, clear: bool) void {
        self.stop(clear);
        self.start() catch |err| {
            log.warn("background video start failed err={}", .{err});
        };
    }

    fn start(self: *BackgroundVideo) !void {
        if (self.thread != null) return;
        self.session_mutex.lock();
        const has_tracks = self.session.tracks.items.len > 0;
        self.session_mutex.unlock();
        if (!has_tracks) return;
        self.dropped_frames.store(0, .monotonic);
        self.accept_frames.store(true, .release);
        self.render_enabled.store(true, .release);
        self.paused.store(false, .release);
        self.seek_enabled.store(false, .release);
        self.thread = try std.Thread.spawn(.{}, threadMain, .{self});
    }

    fn killChildren(self: *BackgroundVideo) void {
        self.child_mutex.lock();
        defer self.child_mutex.unlock();

        if (self.child) |child| {
            self.killChildNoWait(child, "child");
        }
        if (self.audio_child) |child| {
            self.killChildNoWait(child, "audio_child");
        }
        if (self.resolve_child) |child| {
            self.killChildNoWait(child, "resolve_child");
        }
    }

    fn registerChild(self: *BackgroundVideo, child: *std.process.Child) void {
        self.child_mutex.lock();
        self.child = child;
        self.child_mutex.unlock();
    }

    fn clearChild(self: *BackgroundVideo, child: *std.process.Child) void {
        self.child_mutex.lock();
        if (self.child == child) self.child = null;
        self.child_mutex.unlock();
    }

    fn registerResolveChild(self: *BackgroundVideo, child: *std.process.Child) void {
        self.child_mutex.lock();
        self.resolve_child = child;
        self.child_mutex.unlock();
    }

    fn clearResolveChild(self: *BackgroundVideo, child: *std.process.Child) void {
        self.child_mutex.lock();
        if (self.resolve_child == child) self.resolve_child = null;
        self.child_mutex.unlock();
    }

    fn threadMain(self: *BackgroundVideo) void {
        self.threadMain_() catch |err| {
            log.warn("background video thread failed err={}", .{err});
        };
    }

    fn threadMain_(self: *BackgroundVideo) !void {
        if (self.stop_flag.load(.seq_cst)) return;
        const track = self.snapshotCurrentTrack() orelse return;
        defer self.alloc.free(track.url);
        log.info("background video loading provider={} url={s}", .{ track.provider, track.url });

        const source = try self.resolveSource(track.url);
        defer source.deinit(self.alloc);
        log.info("background video source resolved kind={} media={}", .{ source.kind, source.media });
        self.refreshCurrentTrackMetadata(track.url, track.provider) catch |err| {
            log.warn("background metadata resolve failed err={}", .{err});
        };

        defer {
            if (!self.stop_flag.load(.seq_cst)) {
                self.accept_frames.store(false, .release);
                self.render_enabled.store(false, .release);
                self.paused.store(false, .release);
                self.seek_enabled.store(false, .release);
            }
        }

        switch (source.media) {
            .video => {
                const fps = probeFps(self.alloc, source.path) catch |err| err: {
                    log.warn("background video ffprobe failed err={}", .{err});
                    break :err defaultFps();
                };

                if (self.stop_flag.load(.seq_cst)) return;

                if (self.audio_enabled) {
                    self.startAudio(source, track.url) catch |err| {
                        log.warn("background video audio start failed err={}", .{err});
                    };
                }
                defer self.stopAudio();

                try self.decodeVideo(source, fps);
            },
            .audio_only => {
                // Audio-only sources (SoundCloud, direct mp3, etc.) should not
                // leave stale visual state.
                self.sendClear();
                self.render_enabled.store(false, .release);
                self.seek_enabled.store(true, .release);

                if (!self.audio_enabled) return;
                try self.playAudioOnly(source, track.url);
            },
        }
    }

    const TrackSnapshot = struct {
        url: []u8,
        provider: Provider,
    };

    const MetadataField = enum {
        title,
        artist,
    };

    fn snapshotCurrentTrack(self: *BackgroundVideo) ?TrackSnapshot {
        self.session_mutex.lock();
        defer self.session_mutex.unlock();
        const track = self.currentTrackLocked() orelse return null;
        return .{
            .url = self.alloc.dupe(u8, track.url) catch return null,
            .provider = track.provider,
        };
    }

    fn currentTrackLocked(self: *BackgroundVideo) ?*Track {
        const len = self.session.tracks.items.len;
        if (len == 0) return null;
        if (self.session.index >= len) self.session.index = len - 1;
        return &self.session.tracks.items[self.session.index];
    }

    fn rotateTrack(self: *BackgroundVideo, delta: i32) bool {
        self.session_mutex.lock();
        const len = self.session.tracks.items.len;
        if (len <= 1) {
            self.session_mutex.unlock();
            return false;
        }

        var index: i32 = @intCast(self.session.index);
        index += delta;
        if (index < 0) {
            index = @intCast(len - 1);
        } else if (index >= @as(i32, @intCast(len))) {
            index = 0;
        }
        self.session.index = @intCast(index);
        self.session_mutex.unlock();

        self.restart(false);
        return true;
    }

    fn dupCurrentMetadataField(self: *BackgroundVideo, field: MetadataField) ?[]u8 {
        self.session_mutex.lock();
        defer self.session_mutex.unlock();

        const track = self.currentTrackLocked() orelse return null;
        const value = switch (field) {
            .title => track.metadata.title orelse titleFromUrl(track.url),
            .artist => track.metadata.artist,
        } orelse return null;
        return self.alloc.dupe(u8, value) catch null;
    }

    fn refreshCurrentTrackMetadata(self: *BackgroundVideo, url: []const u8, provider: Provider) !void {
        self.session_mutex.lock();
        const state = blk: {
            const track = self.currentTrackLocked() orelse break :blk null;
            if (!std.mem.eql(u8, track.url, url)) break :blk null;
            break :blk track.metadata_status;
        };
        self.session_mutex.unlock();

        if (state == null) return;
        if (state.? != .unresolved) return;

        var metadata = try self.resolveTrackMetadata(url, provider);
        errdefer metadata.deinit(self.alloc);

        self.session_mutex.lock();
        defer self.session_mutex.unlock();
        const track = self.currentTrackLocked() orelse return;
        if (!std.mem.eql(u8, track.url, url)) return;

        track.metadata.deinit(self.alloc);
        track.metadata = metadata;
        track.metadata_status = .resolved;
    }

    fn resolveTrackMetadata(self: *BackgroundVideo, url: []const u8, provider: Provider) !Metadata {
        if (provider == .youtube or provider == .soundcloud) {
            if (try self.resolveYtDlpMetadata(url)) |metadata| return metadata;
        }

        var fallback: Metadata = .{};
        errdefer fallback.deinit(self.alloc);

        if (titleFromUrl(url)) |title| {
            fallback.title = try self.alloc.dupe(u8, title);
        }

        return fallback;
    }

    fn resolveYtDlpMetadata(self: *BackgroundVideo, url: []const u8) !?Metadata {
        var argv = try buildYtDlpArgs(self.alloc, .{
            "--dump-single-json",
            "--skip-download",
            "--no-warnings",
            "--no-playlist",
            url,
        }, .{});
        defer argv.deinit(self.alloc);

        const result = try self.runResolveChild(argv.items);
        defer self.alloc.free(result.stdout);
        defer self.alloc.free(result.stderr);

        if (!termSuccess(result.term)) {
            logYtDlpFailure("metadata", result);
            return null;
        }

        var parsed = std.json.parseFromSlice(std.json.Value, self.alloc, result.stdout, .{}) catch return null;
        defer parsed.deinit();

        const obj = switch (parsed.value) {
            .object => |v| v,
            else => return null,
        };

        var metadata: Metadata = .{};
        errdefer metadata.deinit(self.alloc);

        if (jsonStringField(obj, "title")) |title| {
            metadata.title = try self.alloc.dupe(u8, title);
        }

        if (jsonStringField(obj, "artist")) |artist| {
            metadata.artist = try self.alloc.dupe(u8, artist);
        } else if (jsonStringField(obj, "uploader")) |uploader| {
            metadata.artist = try self.alloc.dupe(u8, uploader);
        } else if (jsonStringField(obj, "channel")) |channel| {
            metadata.artist = try self.alloc.dupe(u8, channel);
        }

        if (jsonStringField(obj, "album")) |album| {
            metadata.album = try self.alloc.dupe(u8, album);
        }

        if (metadata.title == null and metadata.artist == null and metadata.album == null) {
            metadata.deinit(self.alloc);
            return null;
        }
        return metadata;
    }

    fn jsonStringField(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
        const value = obj.get(key) orelse return null;
        return switch (value) {
            .string => |s| if (s.len > 0) s else null,
            else => null,
        };
    }

    fn startAudio(self: *BackgroundVideo, source: Source, url: []const u8) !void {
        if (self.stop_flag.load(.seq_cst)) return;
        const input = switch (source.audio_input) {
            .source_path => source.path,
            .original_url => url,
        };

        const ipc_path = try self.setupAudioIpcPath();
        const ipc_arg = try std.fmt.allocPrint(self.alloc, "--input-ipc-server={s}", .{ipc_path});
        defer self.alloc.free(ipc_arg);

        var argv = std.ArrayList([]const u8).empty;
        defer argv.deinit(self.alloc);
        try argv.appendSlice(self.alloc, &.{
            "mpv",
            "--no-video",
            "--no-terminal",
            "--really-quiet",
            "--profile=low-latency",
            "--audio-display=no",
        });
        try argv.append(self.alloc, ipc_arg);
        try argv.append(self.alloc, input);

        const child = try self.alloc.create(std.process.Child);
        child.* = std.process.Child.init(argv.items, self.alloc);
        child.stdin_behavior = .Ignore;
        child.stdout_behavior = .Ignore;
        child.stderr_behavior = .Ignore;

        try child.spawn();

        if (self.stop_flag.load(.seq_cst)) {
            _ = child.kill() catch {};
            _ = child.wait() catch {};
            self.alloc.destroy(child);
            return;
        }

        self.child_mutex.lock();
        if (self.stop_flag.load(.seq_cst)) {
            self.child_mutex.unlock();
            _ = child.kill() catch {};
            _ = child.wait() catch {};
            self.alloc.destroy(child);
            return;
        }
        self.audio_child = child;
        self.child_mutex.unlock();
    }

    fn playAudioOnly(self: *BackgroundVideo, source: Source, url: []const u8) !void {
        if (self.stop_flag.load(.seq_cst)) return;
        const input = switch (source.audio_input) {
            .source_path => source.path,
            .original_url => url,
        };

        const ipc_path = try self.setupAudioIpcPath();
        const ipc_arg = try std.fmt.allocPrint(self.alloc, "--input-ipc-server={s}", .{ipc_path});
        defer self.alloc.free(ipc_arg);

        var argv = std.ArrayList([]const u8).empty;
        defer argv.deinit(self.alloc);
        try argv.appendSlice(self.alloc, &.{
            "mpv",
            "--no-video",
            "--no-terminal",
            "--really-quiet",
            "--profile=low-latency",
            "--audio-display=no",
        });
        try argv.append(self.alloc, ipc_arg);
        try argv.append(self.alloc, input);

        const child = try self.alloc.create(std.process.Child);
        errdefer self.alloc.destroy(child);

        child.* = std.process.Child.init(argv.items, self.alloc);
        child.stdin_behavior = .Ignore;
        child.stdout_behavior = .Ignore;
        child.stderr_behavior = .Ignore;

        try child.spawn();
        self.registerChild(child);
        defer {
            self.clearChild(child);
            self.clearAudioIpcPath();
            self.alloc.destroy(child);
        }

        _ = child.wait() catch |err| {
            if (!self.stop_flag.load(.seq_cst)) return err;
        };
    }

    fn stopAudio(self: *BackgroundVideo) void {
        self.child_mutex.lock();
        const child = self.audio_child;
        self.audio_child = null;
        self.child_mutex.unlock();

        if (child) |c| {
            self.killChildNoWait(c, "audio_child");
            _ = c.wait() catch {};
            self.alloc.destroy(c);
        }
        self.clearAudioIpcPath();
    }

    fn killChildNoWait(self: *BackgroundVideo, child: *std.process.Child, name: []const u8) void {
        log.info("signaling {s} pid={}", .{ name, child.id });

        // Non-blocking signal path for interactive stop. `Child.kill()`
        // may wait for process termination and can stall UI input.
        std.posix.kill(child.id, std.posix.SIG.TERM) catch |err| switch (err) {
            error.ProcessNotFound => {},
            else => log.warn("kill {s} failed pid={} err={}", .{ name, child.id, err }),
        };

        // TERM is sometimes ignored by media pipelines; force kill best-effort.
        std.posix.kill(child.id, std.posix.SIG.KILL) catch |err| switch (err) {
            error.ProcessNotFound => {},
            else => log.warn("kill -9 {s} failed pid={} err={}", .{ name, child.id, err }),
        };
        _ = self;
    }

    fn signalPause(self: *BackgroundVideo, child: *std.process.Child, paused: bool) void {
        if (paused) {
            std.posix.kill(child.id, std.posix.SIG.STOP) catch |err| switch (err) {
                error.ProcessNotFound => {},
                else => log.warn("pause signal failed pid={} paused={} err={}", .{ child.id, paused, err }),
            };
        } else {
            std.posix.kill(child.id, std.posix.SIG.CONT) catch |err| switch (err) {
                error.ProcessNotFound => {},
                else => log.warn("pause signal failed pid={} paused={} err={}", .{ child.id, paused, err }),
            };
        }
        _ = self;
    }

    fn setupAudioIpcPath(self: *BackgroundVideo) ![]const u8 {
        self.clearAudioIpcPath();
        const nonce = std.crypto.random.int(u64);
        const path = try std.fmt.allocPrint(
            self.alloc,
            "/tmp/ghostty-bgv-{d}-{x}.sock",
            .{ std.c.getpid(), nonce },
        );
        self.child_mutex.lock();
        self.audio_ipc_path = path;
        self.child_mutex.unlock();
        return path;
    }

    fn clearAudioIpcPath(self: *BackgroundVideo) void {
        self.child_mutex.lock();
        const path = self.audio_ipc_path;
        self.audio_ipc_path = null;
        self.child_mutex.unlock();

        if (path) |path_| {
            std.fs.cwd().deleteFile(path_) catch |err| switch (err) {
                error.FileNotFound => {},
                else => log.warn("failed to remove mpv ipc path={s} err={}", .{ path_, err }),
            };
            self.alloc.free(path_);
        }
    }

    fn sendMpvIpcSeek(self: *BackgroundVideo, seconds: i32) bool {
        const payload = std.fmt.allocPrint(
            self.alloc,
            "{{\"command\":[\"seek\",{d},\"relative\"]}}",
            .{seconds},
        ) catch return false;
        defer self.alloc.free(payload);
        return self.sendMpvIpcCommand(payload);
    }

    fn sendMpvIpcCommand(self: *BackgroundVideo, payload: []const u8) bool {
        self.child_mutex.lock();
        const p = self.audio_ipc_path orelse {
            self.child_mutex.unlock();
            return false;
        };
        const path = self.alloc.dupe(u8, p) catch {
            self.child_mutex.unlock();
            return false;
        };
        self.child_mutex.unlock();
        defer self.alloc.free(path);

        const address = std.net.Address.initUnix(path) catch return false;
        const fd = std.posix.socket(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0) catch return false;
        defer std.posix.close(fd);

        std.posix.connect(fd, &address.any, address.getOsSockLen()) catch return false;
        _ = std.posix.write(fd, payload) catch return false;
        _ = std.posix.write(fd, "\n") catch return false;
        return true;
    }

    fn decodeVideo(self: *BackgroundVideo, source: Source, fps: f32) !void {
        if (self.stop_flag.load(.seq_cst)) return;

        const src_dims = probeResolution(self.alloc, source.path) catch |err| err: {
            log.warn("background video probe resolution failed err={}", .{err});
            break :err .{ 1920, 1080 };
        };

        // Cap at 1080p while preserving aspect ratio.
        var width: u32 = src_dims[0];
        var height: u32 = src_dims[1];
        if (width > 1920 or height > 1080) {
            const scale_w = 1920.0 / @as(f32, @floatFromInt(width));
            const scale_h = 1080.0 / @as(f32, @floatFromInt(height));
            const scale = @min(scale_w, scale_h);
            width = @max(1, @as(u32, @intFromFloat(@as(f32, @floatFromInt(width)) * scale)));
            height = @max(1, @as(u32, @intFromFloat(@as(f32, @floatFromInt(height)) * scale)));
        }
        // Ensure even dimensions for codec compatibility.
        width = (width + 1) & ~@as(u32, 1);
        height = (height + 1) & ~@as(u32, 1);

        const vf = try std.fmt.allocPrint(
            self.alloc,
            "scale={d}:{d}:flags=bicubic,fps={d}",
            .{ width, height, fps },
        );
        defer self.alloc.free(vf);

        var argv = [_][]const u8{
            "ffmpeg",
            "-nostdin",
            "-loglevel",
            "error",
            "-re",
            "-i",
            source.path,
            "-an",
            "-vf",
            vf,
            "-f",
            "rawvideo",
            "-pix_fmt",
            "rgba",
            "pipe:1",
        };

        const child = try self.alloc.create(std.process.Child);
        child.* = std.process.Child.init(&argv, self.alloc);
        child.stdin_behavior = .Ignore;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Ignore;

        try child.spawn();

        self.registerChild(child);

        defer {
            self.clearChild(child);

            if (self.stop_flag.load(.seq_cst)) _ = child.kill() catch {};
            _ = child.wait() catch {};
            self.alloc.destroy(child);
        }

        if (self.stop_flag.load(.seq_cst)) return;

        var read_buf: [8192]u8 = undefined;
        var reader = child.stdout.?.reader(&read_buf);
        const pixels = try std.math.mul(usize, @as(usize, width), @as(usize, height));
        const frame_len = try std.math.mul(usize, pixels, 4);

        var frame = try self.alloc.alloc(u8, frame_len);
        defer self.alloc.free(frame);

        while (!self.stop_flag.load(.seq_cst)) {
            var read_total: usize = 0;
            while (read_total < frame_len) {
                const n = try reader.interface.readSliceShort(frame[read_total..]);
                if (n == 0) break;
                read_total += n;
            }

            if (read_total < frame_len) break;

            const payload = frame;
            frame = try self.alloc.alloc(u8, frame_len);

            if (!self.sendFrame(width, height, payload)) {
                self.alloc.free(payload);
                if (self.accept_frames.load(.acquire) and self.render_enabled.load(.acquire)) {
                    const dropped = self.dropped_frames.fetchAdd(1, .monotonic) + 1;
                    if (dropped % 120 == 0) {
                        log.warn("background video dropped frames total={}", .{dropped});
                    }
                }
                continue;
            }
        }
    }

    fn sendFrame(self: *BackgroundVideo, width: u32, height: u32, data: []u8) bool {
        if (!self.accept_frames.load(.acquire)) return false;
        if (!self.render_enabled.load(.acquire)) return false;

        const queued = self.surface.renderer_thread.mailbox.push(.{ .background_video_frame = .{
            .width = width,
            .height = height,
            .data = data,
        } }, .{ .instant = {} });

        if (queued > 0) {
            self.surface.renderer_thread.wakeup.notify() catch {};
            return true;
        }
        return false;
    }

    fn sendClear(self: *BackgroundVideo) void {
        var attempt: u8 = 0;
        while (attempt < 16) : (attempt += 1) {
            if (self.surface.renderer_thread.mailbox.push(
                .{ .background_video_clear = {} },
                .{ .instant = {} },
            ) > 0) {
                self.surface.renderer_thread.wakeup.notify() catch {};
                return;
            }

            // Nudge renderer drain progress once, then retry briefly.
            if (attempt == 0) self.surface.renderer_thread.wakeup.notify() catch {};
            std.Thread.sleep(std.time.ns_per_ms);
        }

        log.warn("failed to enqueue background video clear after retries", .{});
    }

    fn defaultFps() f32 {
        return 30.0;
    }

    const MediaKind = enum { video, audio_only };

    const Source = struct {
        kind: enum { file, stream },
        media: MediaKind,
        audio_input: enum {
            source_path,
            original_url,
        } = .source_path,
        path: []const u8,
        owned: bool,

        fn deinit(self: Source, alloc: Allocator) void {
            if (self.owned) alloc.free(self.path);
        }
    };

    fn resolveSource(self: *BackgroundVideo, url: []const u8) !Source {
        if (mediaKindFromUrl(url)) |media| {
            return .{
                .kind = .stream,
                .media = media,
                .path = try self.alloc.dupe(u8, url),
                .owned = true,
            };
        }

        // Audio-only providers use yt-dlp stream resolution and skip decode.
        if (isSoundCloudUrl(url)) {
            return .{
                .kind = .stream,
                .media = .audio_only,
                .path = try self.resolveAudioStreamUrl(url),
                .owned = true,
            };
        }

        return try self.resolveYtDlpVideoSource(url);
    }

    fn resolveYtDlpVideoSource(self: *BackgroundVideo, url: []const u8) !Source {
        const alloc = self.alloc;

        const live = self.detectLive(url) catch |err| err: {
            log.warn("background video live detection failed err={}", .{err});
            break :err false;
        };

        if (live) {
            log.info("background video youtube live detected: streaming", .{});
            return .{
                .kind = .stream,
                .media = .video,
                .audio_input = .original_url,
                .path = try self.resolveVideoStreamUrl(url),
                .owned = true,
            };
        }

        if (self.resolveVideoStreamUrl(url)) |stream_path| {
            log.info("background video youtube non-live: streaming url (no pre-download)", .{});
            return .{
                .kind = .stream,
                .media = .video,
                .audio_input = .original_url,
                .path = stream_path,
                .owned = true,
            };
        } else |_| {
            log.warn("background video youtube non-live: stream resolve failed, falling back to cache/download", .{});
        }

        const cache_path = try cachePath(alloc, url);
        if (!try fileExists(cache_path)) {
            log.info("background video cache miss: downloading video to {s}", .{cache_path});
            try self.downloadVideo(url, cache_path);
        } else {
            log.info("background video cache hit: using {s}", .{cache_path});
        }

        return .{
            .kind = .file,
            .media = .video,
            .path = cache_path,
            .owned = true,
        };
    }

    fn detectLive(self: *BackgroundVideo, url: []const u8) !bool {
        if (try self.detectLiveWithOptions(url, .{})) return true;
        return try self.detectLiveWithOptions(url, .{ .extractor_args = "youtube:player_client=android" });
    }

    fn detectLiveWithOptions(self: *BackgroundVideo, url: []const u8, opts: YtDlpOptions) !bool {
        const alloc = self.alloc;
        var argv = try buildYtDlpArgs(alloc, .{
            "--dump-single-json",
            "--skip-download",
            "--no-warnings",
            "--no-playlist",
            url,
        }, opts);
        defer argv.deinit(alloc);

        const result = try self.runResolveChild(argv.items);
        defer alloc.free(result.stdout);
        defer alloc.free(result.stderr);

        if (!termSuccess(result.term)) return false;

        const hay = result.stdout;
        if (std.mem.indexOf(u8, hay, "\"is_live\": true") != null) return true;
        if (std.mem.indexOf(u8, hay, "\"live_status\": \"is_live\"") != null) return true;
        if (std.mem.indexOf(u8, hay, "\"live_status\": \"is_upcoming\"") != null) return true;
        return false;
    }

    fn resolveVideoStreamUrl(self: *BackgroundVideo, url: []const u8) ![]const u8 {
        if (try self.resolveStreamUrlWithOptions(url, "bestvideo", .{})) |stream| return stream;
        if (try self.resolveStreamUrlWithOptions(url, "bestvideo", .{ .extractor_args = "youtube:player_client=android" })) |stream| return stream;
        return error.StreamResolveFailed;
    }

    fn resolveAudioStreamUrl(self: *BackgroundVideo, url: []const u8) ![]const u8 {
        if (try self.resolveStreamUrlWithOptions(url, "bestaudio/best", .{})) |stream| return stream;
        return error.StreamResolveFailed;
    }

    fn downloadVideo(self: *BackgroundVideo, url: []const u8, path: []const u8) !void {
        if (try self.downloadVideoWithOptions(url, path, .{})) return;
        if (try self.downloadVideoWithOptions(url, path, .{ .extractor_args = "youtube:player_client=android" })) return;
        return error.DownloadFailed;
    }

    fn probeFps(alloc: Allocator, source: []const u8) !f32 {
        const argv = [_][]const u8{
            "ffprobe",
            "-v",
            "error",
            "-select_streams",
            "v:0",
            "-show_entries",
            "stream=avg_frame_rate",
            "-of",
            "default=nk=1:nw=1",
            source,
        };

        const result = try std.process.Child.run(.{
            .allocator = alloc,
            .argv = &argv,
            .max_output_bytes = 64 * 1024,
        });
        defer alloc.free(result.stderr);

        if (!termSuccess(result.term)) {
            alloc.free(result.stdout);
            return error.ProbeFailed;
        }

        const fps = parseFps(result.stdout) orelse {
            alloc.free(result.stdout);
            return error.ProbeFailed;
        };
        alloc.free(result.stdout);
        return std.math.clamp(fps, 10.0, 60.0);
    }

    fn probeResolution(alloc: Allocator, source: []const u8) ![2]u32 {
        const argv = [_][]const u8{
            "ffprobe",
            "-v",
            "error",
            "-select_streams",
            "v:0",
            "-show_entries",
            "stream=width,height",
            "-of",
            "csv=p=0:s=x",
            source,
        };

        const result = try std.process.Child.run(.{
            .allocator = alloc,
            .argv = &argv,
            .max_output_bytes = 64 * 1024,
        });
        defer alloc.free(result.stdout);
        defer alloc.free(result.stderr);

        if (!termSuccess(result.term)) return error.ProbeFailed;

        const trimmed = std.mem.trim(u8, result.stdout, " \t\r\n");
        const sep = std.mem.indexOfScalar(u8, trimmed, 'x') orelse return error.ProbeFailed;
        const w = std.fmt.parseInt(u32, trimmed[0..sep], 10) catch return error.ProbeFailed;
        const h = std.fmt.parseInt(u32, trimmed[sep + 1 ..], 10) catch return error.ProbeFailed;
        if (w == 0 or h == 0) return error.ProbeFailed;
        return .{ w, h };
    }

    fn parseFps(raw: []const u8) ?f32 {
        const trimmed = std.mem.trim(u8, raw, " \t\r\n");
        if (trimmed.len == 0) return null;
        if (std.mem.indexOfScalar(u8, trimmed, '/')) |idx| {
            const num = std.fmt.parseFloat(f32, trimmed[0..idx]) catch return null;
            const den = std.fmt.parseFloat(f32, trimmed[idx + 1 ..]) catch return null;
            if (den == 0) return null;
            return num / den;
        }
        return std.fmt.parseFloat(f32, trimmed) catch null;
    }

    fn mediaKindFromUrl(url: []const u8) ?MediaKind {
        const ext = fileExtension(url) orelse return null;

        if (isKnownExtension(ext, &.{
            "mp3",
            "m4a",
            "aac",
            "ogg",
            "oga",
            "opus",
            "wav",
            "flac",
        })) return .audio_only;

        if (isKnownExtension(ext, &.{
            "mp4",
            "mov",
            "m4v",
            "webm",
            "mkv",
            "avi",
        })) return .video;

        return null;
    }

    fn providerFromUrl(url: []const u8) Provider {
        if (isSoundCloudUrl(url)) return .soundcloud;
        if (isYouTubeUrl(url)) return .youtube;
        if (mediaKindFromUrl(url) != null) return .direct_media;
        return .generic_url;
    }

    fn isSoundCloudUrl(url: []const u8) bool {
        return containsIgnoreCase(url, "soundcloud.com/") or
            containsIgnoreCase(url, "snd.sc/");
    }

    fn isYouTubeUrl(url: []const u8) bool {
        return containsIgnoreCase(url, "youtube.com/") or
            containsIgnoreCase(url, "youtu.be/");
    }

    fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
        return std.ascii.indexOfIgnoreCase(haystack, needle) != null;
    }

    fn isKnownExtension(ext: []const u8, list: []const []const u8) bool {
        for (list) |known| {
            if (std.ascii.eqlIgnoreCase(ext, known)) return true;
        }
        return false;
    }

    fn fileExtension(raw: []const u8) ?[]const u8 {
        const trim_at = std.mem.indexOfAny(u8, raw, "?#") orelse raw.len;
        const no_query = raw[0..trim_at];
        if (no_query.len == 0) return null;

        const slash = std.mem.lastIndexOfAny(u8, no_query, "/\\");
        const base = if (slash) |idx| no_query[idx + 1 ..] else no_query;
        if (base.len == 0) return null;

        const dot = std.mem.lastIndexOfScalar(u8, base, '.') orelse return null;
        if (dot + 1 >= base.len) return null;
        return base[dot + 1 ..];
    }

    fn titleFromUrl(raw: []const u8) ?[]const u8 {
        const trim_at = std.mem.indexOfAny(u8, raw, "?#") orelse raw.len;
        const no_query = raw[0..trim_at];
        if (no_query.len == 0) return null;

        const slash = std.mem.lastIndexOfAny(u8, no_query, "/\\");
        const base = if (slash) |idx| no_query[idx + 1 ..] else no_query;
        if (base.len == 0) return null;

        const without_ext = if (std.mem.lastIndexOfScalar(u8, base, '.')) |idx|
            base[0..idx]
        else
            base;
        if (without_ext.len == 0) return null;
        return without_ext;
    }

    fn firstNonEmptyLine(buf: []const u8) ?[]const u8 {
        var it = std.mem.splitScalar(u8, buf, '\n');
        while (it.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r\n");
            if (trimmed.len > 0) return trimmed;
        }
        return null;
    }

    fn fileExists(path: []const u8) !bool {
        std.fs.cwd().access(path, .{}) catch |err| switch (err) {
            error.FileNotFound => return false,
            else => return err,
        };
        return true;
    }

    fn cachePath(alloc: Allocator, url: []const u8) ![]const u8 {
        const cache_dir = try cacheDir(alloc);
        defer alloc.free(cache_dir);

        try std.fs.cwd().makePath(cache_dir);
        pruneVideoCacheBestEffort(alloc, cache_dir);

        var hash: [32]u8 = undefined;
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        hasher.update(url);
        hasher.final(&hash);

        var hex_buf: [64]u8 = undefined;
        for (hash, 0..) |byte, i| {
            const hi: u8 = byte >> 4;
            const lo: u8 = byte & 0x0F;
            hex_buf[i * 2] = hexDigit(hi);
            hex_buf[i * 2 + 1] = hexDigit(lo);
        }

        const filename = try std.fmt.allocPrint(alloc, "{s}.mp4", .{hex_buf});
        defer alloc.free(filename);

        return std.fs.path.join(alloc, &.{ cache_dir, filename });
    }

    const CacheEntry = struct {
        name: []u8,
        size: u64,
        mtime: i128,
    };

    fn pruneVideoCacheBestEffort(alloc: Allocator, cache_dir: []const u8) void {
        pruneVideoCache(alloc, cache_dir) catch |err| {
            log.warn("video cache prune failed err={}", .{err});
        };
    }

    fn pruneVideoCache(alloc: Allocator, cache_dir: []const u8) !void {
        var dir = try std.fs.cwd().openDir(cache_dir, .{ .iterate = true });
        defer dir.close();

        var entries: std.ArrayList(CacheEntry) = .empty;
        defer {
            for (entries.items) |entry| alloc.free(entry.name);
            entries.deinit(alloc);
        }

        const now = std.time.nanoTimestamp();
        var total_size: u64 = 0;

        var it = dir.iterate();
        while (try it.next()) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.eql(u8, std.fs.path.extension(entry.name), ".mp4")) continue;

            const stat = dir.statFile(entry.name) catch continue;
            const age_ns = if (now > stat.mtime) now - stat.mtime else 0;

            if (age_ns > video_cache_ttl_ns) {
                dir.deleteFile(entry.name) catch |err| switch (err) {
                    error.FileNotFound => {},
                    else => log.warn("failed to delete stale cache file={s} err={}", .{ entry.name, err }),
                };
                continue;
            }

            try entries.append(alloc, .{
                .name = try alloc.dupe(u8, entry.name),
                .size = stat.size,
                .mtime = stat.mtime,
            });
            total_size +|= stat.size;
        }

        while (total_size > video_cache_max_bytes and entries.items.len > 0) {
            var oldest_index: usize = 0;
            for (entries.items[1..], 1..) |entry, i| {
                if (entry.mtime < entries.items[oldest_index].mtime) {
                    oldest_index = i;
                }
            }

            const victim = entries.swapRemove(oldest_index);
            dir.deleteFile(victim.name) catch |err| switch (err) {
                error.FileNotFound => {},
                else => log.warn("failed to delete cache file={s} err={}", .{ victim.name, err }),
            };

            if (total_size > victim.size) {
                total_size -= victim.size;
            } else {
                total_size = 0;
            }
            alloc.free(victim.name);
        }
    }

    fn cacheDir(alloc: Allocator) ![]const u8 {
        if (comptime builtin.os.tag == .macos) macos: {
            if (std.posix.getenv("XDG_CACHE_HOME") != null) break :macos;
            return try internal_os.macos.cacheDir(alloc, "videos");
        }

        return try internal_os.xdg.cache(alloc, .{ .subdir = "ghostty/videos" });
    }

    fn termSuccess(term: std.process.Child.Term) bool {
        return switch (term) {
            .Exited => |code| code == 0,
            else => false,
        };
    }

    fn hexDigit(v: u8) u8 {
        return if (v < 10) ('0' + v) else ('a' + (v - 10));
    }

    const YtDlpOptions = struct {
        extractor_args: ?[]const u8 = null,
    };

    fn ytDlpCookiesFile() ?[]const u8 {
        const env = std.posix.getenv("GHOSTTY_YTDLP_COOKIES") orelse return null;
        return std.mem.sliceTo(env, 0);
    }

    fn ytDlpCookiesFromBrowser() ?[]const u8 {
        const env = std.posix.getenv("GHOSTTY_YTDLP_COOKIES_FROM_BROWSER") orelse return null;
        return std.mem.sliceTo(env, 0);
    }

    fn buildYtDlpArgs(
        alloc: Allocator,
        base: anytype,
        opts: YtDlpOptions,
    ) !std.ArrayList([]const u8) {
        var argv = std.ArrayList([]const u8).empty;
        try argv.append(alloc, "yt-dlp");
        if (ytDlpCookiesFile()) |path| {
            try argv.append(alloc, "--cookies");
            try argv.append(alloc, path);
        }
        if (ytDlpCookiesFromBrowser()) |browser| {
            try argv.append(alloc, "--cookies-from-browser");
            try argv.append(alloc, browser);
        }
        if (opts.extractor_args) |args| {
            try argv.append(alloc, "--extractor-args");
            try argv.append(alloc, args);
        }
        inline for (base) |arg| {
            try argv.append(alloc, arg);
        }
        return argv;
    }

    fn resolveStreamUrlWithOptions(
        self: *BackgroundVideo,
        url: []const u8,
        format: []const u8,
        opts: YtDlpOptions,
    ) !?[]const u8 {
        const alloc = self.alloc;
        var argv = try buildYtDlpArgs(alloc, .{
            "-g",
            "--no-playlist",
            "-f",
            format,
            url,
        }, opts);
        defer argv.deinit(alloc);

        const result = try self.runResolveChild(argv.items);
        defer alloc.free(result.stderr);

        if (!termSuccess(result.term)) {
            logYtDlpFailure("stream resolve", result);
            alloc.free(result.stdout);
            return null;
        }

        const line = firstNonEmptyLine(result.stdout) orelse {
            alloc.free(result.stdout);
            return null;
        };

        const out = try alloc.dupe(u8, line);
        alloc.free(result.stdout);
        return out;
    }

    fn downloadVideoWithOptions(
        self: *BackgroundVideo,
        url: []const u8,
        path: []const u8,
        opts: YtDlpOptions,
    ) !bool {
        var argv = try buildYtDlpArgs(self.alloc, .{
            "--no-playlist",
            "--no-progress",
            "--merge-output-format",
            "mp4",
            "-f",
            "bestvideo+bestaudio/best",
            "-o",
            path,
            url,
        }, opts);
        defer argv.deinit(self.alloc);

        const result = try self.runResolveChild(argv.items);
        defer self.alloc.free(result.stdout);
        defer self.alloc.free(result.stderr);

        if (!termSuccess(result.term)) {
            logYtDlpFailure("download", result);
            return false;
        }
        return true;
    }

    /// Spawn a child process, register it as `resolve_child` so `killChildren()`
    /// can terminate it, collect stdout/stderr, wait, and return the result.
    /// This replaces `std.process.Child.run` for yt-dlp invocations.
    fn runResolveChild(self: *BackgroundVideo, argv: []const []const u8) !std.process.Child.RunResult {
        const alloc = self.alloc;

        const child = try alloc.create(std.process.Child);
        defer alloc.destroy(child);

        child.* = std.process.Child.init(argv, alloc);
        child.stdin_behavior = .Ignore;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;

        try child.spawn();
        self.registerResolveChild(child);
        errdefer {
            _ = child.kill() catch {};
        }
        defer self.clearResolveChild(child);

        var stdout: std.ArrayList(u8) = .empty;
        defer stdout.deinit(alloc);
        var stderr: std.ArrayList(u8) = .empty;
        defer stderr.deinit(alloc);

        try child.collectOutput(alloc, &stdout, &stderr, 5 * 1024 * 1024);

        return .{
            .stdout = try stdout.toOwnedSlice(alloc),
            .stderr = try stderr.toOwnedSlice(alloc),
            .term = try child.wait(),
        };
    }

    fn logYtDlpFailure(ctx: []const u8, result: std.process.Child.RunResult) void {
        const stderr = std.mem.trim(u8, result.stderr, " \t\r\n");
        if (stderr.len == 0) {
            log.warn("yt-dlp {s} failed term={}", .{ ctx, result.term });
            return;
        }
        const tail = if (stderr.len > 2048) stderr[stderr.len - 2048 ..] else stderr;
        log.warn("yt-dlp {s} failed term={} stderr={s}", .{ ctx, result.term, tail });
    }
};

test "background video media kind classification" {
    try std.testing.expectEqual(
        BackgroundVideo.MediaKind.audio_only,
        BackgroundVideo.mediaKindFromUrl("https://cdn.example.com/track.MP3").?,
    );
    try std.testing.expectEqual(
        BackgroundVideo.MediaKind.audio_only,
        BackgroundVideo.mediaKindFromUrl("https://cdn.example.com/track.m4a?sig=1").?,
    );
    try std.testing.expectEqual(
        BackgroundVideo.MediaKind.video,
        BackgroundVideo.mediaKindFromUrl("https://cdn.example.com/clip.webm#t=1").?,
    );
    try std.testing.expect(BackgroundVideo.mediaKindFromUrl("https://example.com/page") == null);
}

test "background video provider detection" {
    try std.testing.expect(BackgroundVideo.isSoundCloudUrl("https://soundcloud.com/artist/track"));
    try std.testing.expect(BackgroundVideo.isSoundCloudUrl("https://SND.SC/xyz"));
    try std.testing.expect(BackgroundVideo.isYouTubeUrl("https://www.youtube.com/watch?v=abc"));
    try std.testing.expect(BackgroundVideo.isYouTubeUrl("https://youtu.be/abc"));
    try std.testing.expect(!BackgroundVideo.isSoundCloudUrl("https://example.com/audio.mp3"));
    try std.testing.expectEqual(
        BackgroundVideo.Provider.youtube,
        BackgroundVideo.providerFromUrl("https://www.youtube.com/watch?v=abc"),
    );
    try std.testing.expectEqual(
        BackgroundVideo.Provider.soundcloud,
        BackgroundVideo.providerFromUrl("https://soundcloud.com/artist/track"),
    );
    try std.testing.expectEqual(
        BackgroundVideo.Provider.direct_media,
        BackgroundVideo.providerFromUrl("https://example.com/music.mp3"),
    );
}

test "background video title from url" {
    try std.testing.expectEqualStrings(
        "praise-break-thing2",
        BackgroundVideo.titleFromUrl("https://soundcloud.com/jonah1plus1plus1/praise-break-thing2").?,
    );
    try std.testing.expectEqualStrings(
        "clip",
        BackgroundVideo.titleFromUrl("https://cdn.example.com/clip.mp4?sig=1").?,
    );
}

test "background media queue parsing" {
    var session: BackgroundVideo.BackgroundMediaSession = .{};
    defer session.deinit(std.testing.allocator);

    try session.setFromInput(
        std.testing.allocator,
        " https://a.example/1.mp3 , , https://b.example/2.mp4 ",
    );
    try std.testing.expectEqual(@as(usize, 2), session.tracks.items.len);
    try std.testing.expectEqualStrings("https://a.example/1.mp3", session.tracks.items[0].url);
    try std.testing.expectEqualStrings("https://b.example/2.mp4", session.tracks.items[1].url);
}
