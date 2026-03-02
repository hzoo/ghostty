const std = @import("std");
const builtin = @import("builtin");
const configpkg = @import("../config.zig");
const audio = @import("../audio/Glossolalia.zig");
const shadertoy = @import("shadertoy.zig");

const Allocator = std.mem.Allocator;
const log = std.log.scoped(.glossolalia);

pub const State = struct {
    audio_capture: ?*audio.Capture,
    config: Config,
    raw_debug_gain: f32,
    beat_bounce: f32,
    dsp_override_active: bool,
    last_dsp_override: DspOverride,

    pub const Config = struct {
        enabled: bool,
        strength: f32,
        debug: bool,
        device: ?[:0]const u8,

        pub fn fromConfig(config: *const configpkg.Config) Config {
            return .{
                .enabled = config.glossolalia.isEnabled(),
                .strength = config.@"glossolalia-strength",
                .debug = config.glossolalia.isDebug(),
                .device = config.@"glossolalia-device",
            };
        }
    };

    pub const DspOverride = struct {
        smoothing: f32 = 0.8,
        avg_decay: f32 = 0.998,
        avg_scale: f32 = 3.0,
        energy_decay: f32 = 0.75,
        snare_attack: f32 = 0.5,
        snare_decay: f32 = 0.8,

        pub fn toParams(self: DspOverride) audio.DspParams {
            return .{
                .smoothing = self.smoothing,
                .avg_decay = self.avg_decay,
                .avg_scale = self.avg_scale,
                .energy_decay = self.energy_decay,
                .snare_attack = self.snare_attack,
                .snare_decay = self.snare_decay,
            };
        }

        pub fn fromParams(params: audio.DspParams) DspOverride {
            return .{
                .smoothing = params.smoothing,
                .avg_decay = params.avg_decay,
                .avg_scale = params.avg_scale,
                .energy_decay = params.energy_decay,
                .snare_attack = params.snare_attack,
                .snare_decay = params.snare_decay,
            };
        }
    };

    pub fn init(alloc: Allocator, config: Config) State {
        const defaults: audio.DspParams = .{};
        const capture = audio.Capture.init(alloc, config.device) catch |err| err: {
            log.warn("audio init failed err={}", .{err});
            break :err null;
        };
        return .{
            .audio_capture = capture,
            .config = config,
            .raw_debug_gain = 1.0,
            .beat_bounce = 0.0,
            .dsp_override_active = false,
            .last_dsp_override = DspOverride.fromParams(defaults),
        };
    }

    pub fn deinit(self: *State) void {
        if (self.audio_capture) |capture| capture.deinit();
        self.* = undefined;
    }

    pub fn updateConfig(self: *State, alloc: Allocator, config: Config) void {
        const device_changed =
            if (self.config.device) |old|
                if (config.device) |new|
                    !std.mem.eql(u8, old, new)
                else
                    true
            else
                config.device != null;

        if (device_changed) {
            if (self.audio_capture) |capture| capture.deinit();
            self.audio_capture = audio.Capture.init(alloc, config.device) catch |err| err: {
                log.warn("audio reinit failed err={}", .{err});
                break :err null;
            };
            self.dsp_override_active = false;
        }
        self.config = config;
    }

    pub fn setDspOverride(self: *State, dsp: ?DspOverride) void {
        const capture = self.audio_capture orelse return;

        if (dsp) |override| {
            if (!self.dsp_override_active or !std.meta.eql(self.last_dsp_override, override)) {
                capture.setDspParams(override.toParams());
                self.last_dsp_override = override;
                self.dsp_override_active = true;
            }
            return;
        }

        if (self.dsp_override_active) {
            const defaults: audio.DspParams = .{};
            capture.setDspParams(defaults);
            self.last_dsp_override = DspOverride.fromParams(defaults);
            self.dsp_override_active = false;
        }
    }

    /// Returns compiled shader source for the glossolalia post-processing pipeline.
    pub fn shaderSource(
        alloc: Allocator,
        _: Config,
        target: shadertoy.Target,
        y_is_down: bool,
    ) ?[:0]const u8 {
        const src = @embedFile("shaders/glossolalia_equalizer_glyph.glsl");
        const define = if (y_is_down)
            "#define GLOSS_Y_IS_DOWN 1\n"
        else
            "#define GLOSS_Y_IS_DOWN 0\n";
        const prefixed = std.mem.concat(alloc, u8, &[_][]const u8{
            define,
            src,
        }) catch |err| {
            log.warn("shader concat failed err={}", .{err});
            return null;
        };
        return shadertoy.loadFromSource(alloc, prefixed, target) catch |err| {
            log.warn("shader compile failed err={}", .{err});
            return null;
        };
    }

    /// Writes glossolalia-specific uniforms: audio spectrum, envelopes, config.
    pub fn updateUniforms(self: *State, uniforms: *shadertoy.Uniforms) void {
        const wave_freq: f32 = 1.4;
        const wave_speed: f32 = 0.18;
        const ripple_freq: f32 = 6.0;
        const ripple_speed: f32 = 1.8;
        const color_amount: f32 = 0.5;

        uniforms.glossolalia = .{
            self.config.strength,
            wave_freq,
            wave_speed,
            if (self.config.debug) 1.0 else 0.0,
        };
        uniforms.glossolalia2 = .{
            ripple_freq,
            color_amount,
            self.raw_debug_gain,
            ripple_speed,
        };

        if (self.audio_capture) |capture| {
            var magnitude: audio.Capture.Spectrum = undefined;
            capture.readSpectrum(&magnitude);
            const snare_env = capture.readSnareEnv();

            var raw: audio.Capture.Spectrum = undefined;
            capture.readRawSpectrum(&raw);

            const spectrum = magnitude;
            var kick: f32 = 0.0;
            var snare: f32 = 0.0;
            var hat: f32 = 0.0;
            var raw_peak: f32 = 0.0;
            for (0..audio.band_count) |i| {
                const value = spectrum[i];
                if (i < 4) {
                    kick += value;
                } else if (i < 12) {
                    snare += value;
                } else if (i < 24) {
                    hat += value;
                }
                raw_peak = @max(raw_peak, raw[i]);
            }
            kick /= 4.0;
            snare /= 8.0;
            hat /= 12.0;

            const snare_mix = @max(snare_env, snare * 0.65);
            const bounce_target = std.math.clamp(
                kick * 0.88 + snare_mix * 0.62 + hat * 0.18,
                0.0,
                1.0,
            );
            if (bounce_target > self.beat_bounce) {
                self.beat_bounce = bounce_target;
            } else {
                self.beat_bounce *= 0.88;
            }
            if (self.beat_bounce < 0.01) self.beat_bounce = 0.0;

            uniforms.glossolalia3 = .{ kick, snare_env, hat, self.beat_bounce };

            const target_peak: f32 = 0.85;
            const gain = if (raw_peak > 1e-4) target_peak / raw_peak else 1.0;
            const clamped_gain = std.math.clamp(gain, 1.0, 8.0);
            self.raw_debug_gain = self.raw_debug_gain * 0.9 + clamped_gain * 0.1;
            uniforms.glossolalia2[2] = self.raw_debug_gain;

            for (0..16) |i| {
                const base = i * 4;
                uniforms.audio_spectrum[i] = .{
                    spectrum[base],
                    spectrum[base + 1],
                    spectrum[base + 2],
                    spectrum[base + 3],
                };
                uniforms.audio_spectrum_raw[i] = .{
                    raw[base],
                    raw[base + 1],
                    raw[base + 2],
                    raw[base + 3],
                };
            }
        } else {
            uniforms.audio_spectrum = @splat(@splat(0));
            uniforms.audio_spectrum_raw = @splat(@splat(0));
            uniforms.glossolalia3 = @splat(0);
            self.raw_debug_gain = 1.0;
            self.beat_bounce = 0.0;
            uniforms.glossolalia2[2] = self.raw_debug_gain;
        }
    }

    /// Whether glossolalia needs forced animation (no frame skipping).
    pub fn forcesAnimation(self: *const State) bool {
        return self.audio_capture != null;
    }
};
