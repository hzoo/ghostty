const std = @import("std");
const builtin = @import("builtin");

const Allocator = std.mem.Allocator;
const log = std.log.scoped(.glossolalia);

pub const band_count = 64;
pub const fft_size = 512;
pub const fft_bins = fft_size / 2;
pub const fft_log2 = std.math.log2_int(usize, fft_size);

pub const DspParams = struct {
    smoothing: f32 = 0.8,
    avg_decay: f32 = 0.998,
    avg_scale: f32 = 3.0,
    energy_decay: f32 = 0.75,
    db_min: f32 = -100.0,
    db_max: f32 = -30.0,
    snare_band_start: u8 = 6,
    snare_band_end: u8 = 16,
    snare_attack: f32 = 0.5,
    snare_decay: f32 = 0.8,
};

pub const Capture = if (builtin.os.tag == .macos) struct {
    const Self = @This();
    const c = @cImport({
        @cInclude("miniaudio.h");
    });

    pub const Spectrum = [band_count]f32;

    allocator: Allocator,
    device: c.ma_device,
    sample_rate: u32,
    samples: []f32,
    scratch: []f32,
    window: []f32,
    bin_magnitudes: []f32,
    write_index: std.atomic.Value(u32),
    sample_counter: std.atomic.Value(u64),
    last_sample_counter: u64,
    running: std.atomic.Value(u8),
    spectrum_index: std.atomic.Value(u8),
    spectrum_buffers: [2]Spectrum,
    raw_spectrum_index: std.atomic.Value(u8),
    raw_spectrum_buffers: [2]Spectrum,
    band_edges: [band_count + 1]usize,
    bit_reverse_indices: [fft_size]u16,
    twiddle_re: [fft_log2][fft_size / 2]f32,
    twiddle_im: [fft_log2][fft_size / 2]f32,
    smoothed: Spectrum,
    energy_smoothed: Spectrum,
    avg: Spectrum,
    prev_smoothed: Spectrum,
    snare_env: f32,
    params: DspParams,
    params_mutex: std.Thread.Mutex,
    analysis_thread: ?std.Thread,

    const loopback_names = [_][]const u8{ "BlackHole", "Loopback", "Soundflower" };

    pub fn init(allocator: Allocator, device_name: ?[:0]const u8) !*Self {
        var self = try allocator.create(Self);
        errdefer allocator.destroy(self);

        self.* = .{
            .allocator = allocator,
            .device = undefined,
            .sample_rate = 0,
            .samples = &.{},
            .scratch = &.{},
            .window = &.{},
            .bin_magnitudes = &.{},
            .write_index = std.atomic.Value(u32).init(0),
            .sample_counter = std.atomic.Value(u64).init(0),
            .last_sample_counter = std.math.maxInt(u64),
            .running = std.atomic.Value(u8).init(0),
            .spectrum_index = std.atomic.Value(u8).init(0),
            .spectrum_buffers = .{
                std.mem.zeroes(Spectrum),
                std.mem.zeroes(Spectrum),
            },
            .raw_spectrum_index = std.atomic.Value(u8).init(0),
            .raw_spectrum_buffers = .{
                std.mem.zeroes(Spectrum),
                std.mem.zeroes(Spectrum),
            },
            .band_edges = [_]usize{0} ** (band_count + 1),
            .bit_reverse_indices = [_]u16{0} ** fft_size,
            .twiddle_re = [_][fft_size / 2]f32{[_]f32{0} ** (fft_size / 2)} ** fft_log2,
            .twiddle_im = [_][fft_size / 2]f32{[_]f32{0} ** (fft_size / 2)} ** fft_log2,
            .smoothed = std.mem.zeroes(Spectrum),
            .energy_smoothed = std.mem.zeroes(Spectrum),
            .avg = std.mem.zeroes(Spectrum),
            .prev_smoothed = std.mem.zeroes(Spectrum),
            .snare_env = 0.0,
            .params = .{},
            .params_mutex = .{},
            .analysis_thread = null,
        };

        self.samples = try allocator.alloc(f32, fft_size);
        errdefer allocator.free(self.samples);
        self.scratch = try allocator.alloc(f32, fft_size);
        errdefer allocator.free(self.scratch);
        self.window = try allocator.alloc(f32, fft_size);
        errdefer allocator.free(self.window);
        self.bin_magnitudes = try allocator.alloc(f32, fft_bins);
        errdefer allocator.free(self.bin_magnitudes);

        @memset(self.samples, 0);
        @memset(self.scratch, 0);
        @memset(self.bin_magnitudes, 0);
        self.initWindow();
        self.initFftTables();

        // Enumerate capture devices and find a matching one.
        var ctx: c.ma_context = undefined;
        if (c.ma_context_init(null, 0, null, &ctx) != c.MA_SUCCESS) {
            return error.ContextInitFailed;
        }
        defer _ = c.ma_context_uninit(&ctx);

        var p_capture_infos: [*c]c.ma_device_info = undefined;
        var capture_count: c.ma_uint32 = 0;
        _ = c.ma_context_get_devices(&ctx, null, null, &p_capture_infos, &capture_count);

        var selected_id: ?c.ma_device_id = null;
        const count: usize = @intCast(capture_count);

        for (0..count) |i| {
            const info = p_capture_infos[i];
            const name_ptr: [*:0]const u8 = @ptrCast(&info.name);
            const name = std.mem.sliceTo(name_ptr, 0);

            if (device_name) |search| {
                // User-specified substring match
                if (std.mem.indexOf(u8, name, search) != null) {
                    log.info("glossolalia: selected device '{s}' (user match)", .{name});
                    selected_id = info.id;
                    break;
                }
            } else {
                // Auto-detect known loopback devices
                for (&loopback_names) |lb_name| {
                    if (std.mem.indexOf(u8, name, lb_name) != null) {
                        log.info("glossolalia: auto-detected loopback '{s}'", .{name});
                        selected_id = info.id;
                        break;
                    }
                }
                if (selected_id != null) break;
            }
        }

        if (selected_id == null) {
            log.info("glossolalia: using default capture device", .{});
        }

        var device_config = c.ma_device_config_init(c.ma_device_type_capture);
        device_config.capture.format = c.ma_format_f32;
        device_config.capture.channels = 1;
        device_config.sampleRate = 0;
        device_config.dataCallback = dataCallback;
        device_config.pUserData = self;

        if (selected_id) |*id| {
            device_config.capture.pDeviceID = id;
        }

        if (c.ma_device_init(null, &device_config, &self.device) != c.MA_SUCCESS) {
            return error.DeviceInitFailed;
        }
        errdefer c.ma_device_uninit(&self.device);

        self.sample_rate = @intCast(self.device.sampleRate);
        self.computeBandEdges();

        if (c.ma_device_start(&self.device) != c.MA_SUCCESS) {
            return error.DeviceStartFailed;
        }

        self.running.store(1, .release);
        self.analysis_thread = try std.Thread.spawn(.{}, analysisMain, .{self});

        return self;
    }

    pub fn deinit(self: *Self) void {
        self.running.store(0, .release);
        if (self.analysis_thread) |thread| thread.join();

        c.ma_device_uninit(&self.device);

        self.allocator.free(self.window);
        self.allocator.free(self.scratch);
        self.allocator.free(self.samples);
        self.allocator.free(self.bin_magnitudes);
        self.allocator.destroy(self);
    }

    pub fn readSpectrum(self: *Self, out: *Spectrum) void {
        const index = self.spectrum_index.load(.acquire);
        out.* = self.spectrum_buffers[index];
    }

    pub fn readSpectra(self: *Self, magnitude: *Spectrum, onset: *Spectrum) void {
        const index = self.spectrum_index.load(.acquire);
        magnitude.* = self.spectrum_buffers[index];
        onset.* = std.mem.zeroes(Spectrum);
    }

    pub fn readRawSpectrum(self: *Self, out: *Spectrum) void {
        const index = self.raw_spectrum_index.load(.acquire);
        out.* = self.raw_spectrum_buffers[index];
    }

    pub fn readSnareEnv(self: *Self) f32 {
        return self.snare_env;
    }

    pub fn setDspParams(self: *Self, params: DspParams) void {
        self.params_mutex.lock();
        defer self.params_mutex.unlock();
        self.params = params;
    }

    fn initWindow(self: *Self) void {
        const count = fft_size - 1;
        for (self.window, 0..) |*value, i| {
            const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(count));
            value.* = 0.5 - 0.5 * std.math.cos(std.math.tau * t);
        }
    }

    fn computeBandEdges(self: *Self) void {
        const sr = @as(f32, @floatFromInt(self.sample_rate));
        if (sr <= 0) {
            @memset(&self.band_edges, 0);
            return;
        }

        const bin_hz: f32 = sr / @as(f32, @floatFromInt(fft_size));
        const nyquist: f32 = sr * 0.5;
        const f_min: f32 = 20.0;
        const f_max: f32 = @min(20000.0, nyquist);
        var edges: [band_count + 1]usize = undefined;
        const ratio: f32 = f_max / f_min;
        if (ratio <= 1.0) {
            for (0..band_count) |i| {
                edges[i] = (fft_bins * i) / band_count;
            }
            edges[band_count] = fft_bins;
            self.band_edges = edges;
            return;
        }

        edges[0] = 0;
        edges[band_count] = fft_bins;

        for (1..band_count) |i| {
            const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(band_count));
            const freq = f_min * std.math.pow(f32, ratio, t);
            const bin_f = freq / @max(bin_hz, 1e-6);
            var bin: usize = @intFromFloat(bin_f);
            if (bin > fft_bins) bin = fft_bins;
            edges[i] = bin;
        }

        // Enforce monotonic edges with at least 1 bin per band.
        var min_bin: usize = 0;
        for (1..band_count) |i| {
            const remaining = band_count - i;
            const max_bin = fft_bins - remaining;
            var v = edges[i];
            if (v < min_bin + 1) v = min_bin + 1;
            if (v > max_bin) v = max_bin;
            edges[i] = v;
            min_bin = v;
        }
        edges[band_count] = fft_bins;

        self.band_edges = edges;
    }

    fn initFftTables(self: *Self) void {
        for (0..fft_size) |i| {
            self.bit_reverse_indices[i] = @intCast(bitReverse(i, fft_log2));
        }

        for (0..fft_log2) |stage| {
            const shift: u6 = @intCast(stage + 1);
            const m: usize = @as(usize, 1) << shift;
            const half_m: usize = m >> 1;
            const angle_step: f32 = -std.math.tau / @as(f32, @floatFromInt(m));
            for (0..half_m) |j| {
                const angle = angle_step * @as(f32, @floatFromInt(j));
                self.twiddle_re[stage][j] = std.math.cos(angle);
                self.twiddle_im[stage][j] = std.math.sin(angle);
            }
        }
    }

    fn analysisMain(self: *Self) void {
        const interval = 16 * std.time.ns_per_ms;
        while (self.running.load(.acquire) == 1) {
            self.updateSpectrum();
            std.Thread.sleep(interval);
        }
    }

    fn updateSpectrum(self: *Self) void {
        const sample_count = self.sample_counter.load(.acquire);
        if (sample_count == self.last_sample_counter) {
            self.decaySpectrum();
            return;
        }
        self.last_sample_counter = sample_count;

        const current_write = self.write_index.load(.acquire);
        const peak = self.copySamples(current_write);
        if (peak < 0.0005) {
            self.decaySpectrum();
            return;
        }

        // Apply window in-place.
        for (self.scratch, self.window) |*s, w| {
            s.* *= w;
        }

        // Bit-reverse permutation (in-place swap).
        for (0..fft_size) |i| {
            const j: usize = self.bit_reverse_indices[i];
            if (j > i) {
                std.mem.swap(f32, &self.scratch[i], &self.scratch[j]);
            }
        }

        // In-place Cooley-Tukey radix-2 DIT FFT.
        var im_buf: [fft_size]f32 = @splat(0);

        var stage: usize = 0;
        while (stage < fft_log2) : (stage += 1) {
            const shift: u6 = @intCast(stage + 1);
            const m: usize = @as(usize, 1) << shift;
            const half_m: usize = m >> 1;

            var k: usize = 0;
            while (k < fft_size) : (k += m) {
                var j: usize = 0;
                while (j < half_m) : (j += 1) {
                    const wr = self.twiddle_re[stage][j];
                    const wi = self.twiddle_im[stage][j];

                    const idx_even = k + j;
                    const idx_odd = k + j + half_m;

                    const tr = wr * self.scratch[idx_odd] - wi * im_buf[idx_odd];
                    const ti = wr * im_buf[idx_odd] + wi * self.scratch[idx_odd];

                    self.scratch[idx_odd] = self.scratch[idx_even] - tr;
                    im_buf[idx_odd] = im_buf[idx_even] - ti;
                    self.scratch[idx_even] += tr;
                    im_buf[idx_even] += ti;
                }
            }
        }

        // Extract magnitudes for the first N/2 bins.
        for (0..fft_bins) |k| {
            const re = self.scratch[k];
            const im = im_buf[k];
            self.bin_magnitudes[k] = std.math.sqrt(re * re + im * im);
        }

        var magnitudes: Spectrum = std.mem.zeroes(Spectrum);
        self.params_mutex.lock();
        const params = self.params;
        self.params_mutex.unlock();

        const min_db: f32 = params.db_min;
        const max_db: f32 = params.db_max;
        const db_range: f32 = @max(max_db - min_db, 1.0);
        const norm_scale: f32 = @as(f32, @floatFromInt(fft_size)) * 0.5;
        const avg_decay: f32 = params.avg_decay;
        const avg_floor: f32 = 0.02;
        const avg_scale: f32 = params.avg_scale;
        const energy_decay: f32 = params.energy_decay;
        const noise_gate_abs: f32 = 0.015;
        const noise_gate_rel: f32 = 0.20;
        const headroom_min: f32 = 0.12;
        const absolute_headroom: f32 = 0.70;
        const absolute_mix: f32 = 0.36;
        const snare_start: usize = @min(@as(usize, params.snare_band_start), band_count - 1);
        const snare_end: usize = @min(
            @max(@as(usize, params.snare_band_end), snare_start + 1),
            band_count,
        );

        var raw: Spectrum = undefined;
        var snare_transient: f32 = 0.0;
        for (0..band_count) |band| {
            const start: usize = self.band_edges[band];
            const end: usize = self.band_edges[band + 1];

            var sum: f32 = 0.0;
            var count: u32 = 0;
            var i: usize = start;
            while (i < end and i < fft_bins) : (i += 1) {
                sum += self.bin_magnitudes[i];
                count += 1;
            }

            const mag = if (count > 0)
                sum / @as(f32, @floatFromInt(count))
            else
                0.0;

            const mag_norm = mag / @max(norm_scale, 1.0);
            const db = 20.0 * std.math.log10(mag_norm + 1e-8);
            var value = (db - min_db) / db_range;
            value = std.math.clamp(value, 0.0, 1.0);
            raw[band] = value;

            const prev = self.smoothed[band];
            self.smoothed[band] =
                self.smoothed[band] * params.smoothing + value * (1.0 - params.smoothing);
            self.prev_smoothed[band] = prev;
            self.avg[band] =
                self.avg[band] * avg_decay + self.smoothed[band] * (1.0 - avg_decay);

            const baseline = @max(self.avg[band], avg_floor);
            const gate = @max(noise_gate_abs, baseline * noise_gate_rel);
            const deviation = @max(self.smoothed[band] - baseline - gate, 0.0);
            const headroom = @max(1.0 - baseline, headroom_min);
            const transient = std.math.clamp(deviation / headroom * avg_scale * 2.0, 0.0, 1.0);
            const absolute = std.math.clamp(
                (self.smoothed[band] - noise_gate_abs) / absolute_headroom,
                0.0,
                1.0,
            );
            const energy = @max(transient, absolute * absolute_mix);
            self.energy_smoothed[band] =
                self.energy_smoothed[band] * energy_decay + energy * (1.0 - energy_decay);
            magnitudes[band] = self.energy_smoothed[band];

            if (band >= snare_start and band < snare_end) {
                const delta = @max(self.smoothed[band] - self.prev_smoothed[band], 0.0);
                snare_transient += delta;
            }
        }

        snare_transient /= @as(f32, @floatFromInt(snare_end - snare_start));
        self.snare_env = self.snare_env * params.snare_decay +
            snare_transient * params.snare_attack;
        self.snare_env = std.math.clamp(self.snare_env, 0.0, 1.0);

        self.publishSpectrum(magnitudes, raw);
    }

    fn decaySpectrum(self: *Self) void {
        var magnitudes: Spectrum = std.mem.zeroes(Spectrum);
        const raw: Spectrum = std.mem.zeroes(Spectrum);

        self.params_mutex.lock();
        const params = self.params;
        self.params_mutex.unlock();

        const avg_decay: f32 = params.avg_decay;
        const avg_floor: f32 = 0.02;
        const avg_scale: f32 = params.avg_scale;
        const energy_decay: f32 = params.energy_decay;
        const noise_gate_abs: f32 = 0.015;
        const noise_gate_rel: f32 = 0.20;
        const headroom_min: f32 = 0.12;
        const absolute_headroom: f32 = 0.70;
        const absolute_mix: f32 = 0.36;
        const silence_release: f32 = 0.78;

        for (0..band_count) |band| {
            const prev = self.smoothed[band];
            const smoothed = prev * params.smoothing;
            self.smoothed[band] = smoothed;
            self.prev_smoothed[band] = prev;
            self.avg[band] = self.avg[band] * avg_decay;

            const baseline = @max(self.avg[band], avg_floor);
            const gate = @max(noise_gate_abs, baseline * noise_gate_rel);
            const deviation = @max(smoothed - baseline - gate, 0.0);
            const headroom = @max(1.0 - baseline, headroom_min);
            const transient = std.math.clamp(deviation / headroom * avg_scale * 2.0, 0.0, 1.0);
            const absolute = std.math.clamp(
                (smoothed - noise_gate_abs) / absolute_headroom,
                0.0,
                1.0,
            );
            const energy = @max(transient, absolute * absolute_mix);
            self.energy_smoothed[band] =
                self.energy_smoothed[band] * energy_decay + energy * (1.0 - energy_decay);
            self.energy_smoothed[band] *= silence_release;
            magnitudes[band] = self.energy_smoothed[band];
        }

        self.snare_env = self.snare_env * params.snare_decay * 0.9;
        self.snare_env = std.math.clamp(self.snare_env, 0.0, 1.0);

        self.publishSpectrum(magnitudes, raw);
    }

    fn publishSpectrum(self: *Self, magnitudes: Spectrum, raw: Spectrum) void {
        const next_index: u8 = self.spectrum_index.load(.acquire) ^ 1;
        self.spectrum_buffers[next_index] = magnitudes;
        self.spectrum_index.store(next_index, .release);

        const raw_next: u8 = self.raw_spectrum_index.load(.acquire) ^ 1;
        self.raw_spectrum_buffers[raw_next] = raw;
        self.raw_spectrum_index.store(raw_next, .release);
    }

    fn bitReverse(val: usize, comptime bits: comptime_int) usize {
        var v = val;
        var r: usize = 0;
        inline for (0..bits) |_| {
            r = (r << 1) | (v & 1);
            v >>= 1;
        }
        return r;
    }

    fn copySamples(self: *Self, start: u32) f32 {
        var index: usize = @intCast(start);
        var peak: f32 = 0.0;
        for (self.scratch) |*value| {
            const sample = self.samples[index];
            value.* = sample;
            const abs_sample = @abs(sample);
            if (abs_sample > peak) peak = abs_sample;
            index = (index + 1) % fft_size;
        }
        return peak;
    }

    fn dataCallback(
        device: [*c]c.ma_device,
        output: ?*anyopaque,
        input: ?*const anyopaque,
        frame_count: c.ma_uint32,
    ) callconv(.c) void {
        _ = output;

        if (input == null) return;
        const user_ptr = device.*.pUserData orelse return;
        const self: *Self = @ptrCast(@alignCast(user_ptr));
        const samples_in: [*]const f32 = @ptrCast(@alignCast(input.?));

        var index: usize = @intCast(self.write_index.load(.monotonic));
        var i: usize = 0;
        const frame_total: usize = @intCast(frame_count);
        while (i < frame_total) : (i += 1) {
            self.samples[index] = samples_in[i];
            index = (index + 1) % fft_size;
        }
        self.write_index.store(@intCast(index), .release);
        _ = self.sample_counter.fetchAdd(@intCast(frame_total), .release);
    }
} else struct {
    const Self = @This();
    pub const Spectrum = [band_count]f32;

    pub fn init(_: Allocator, _: ?[:0]const u8) !*Self {
        return error.Unsupported;
    }

    pub fn deinit(_: *Self) void {}

    pub fn readSpectrum(_: *Self, out: *Spectrum) void {
        out.* = std.mem.zeroes(Spectrum);
    }

    pub fn readSpectra(_: *Self, magnitude: *Spectrum, onset: *Spectrum) void {
        magnitude.* = std.mem.zeroes(Spectrum);
        onset.* = std.mem.zeroes(Spectrum);
    }

    pub fn readRawSpectrum(_: *Self, out: *Spectrum) void {
        out.* = std.mem.zeroes(Spectrum);
    }

    pub fn readSnareEnv(_: *Self) f32 {
        return 0.0;
    }

    pub fn setDspParams(_: *Self, _: DspParams) void {}
};
