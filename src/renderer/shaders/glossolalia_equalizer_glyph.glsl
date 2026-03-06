#ifndef GLOSS_Y_IS_DOWN
#define GLOSS_Y_IS_DOWN 1
#endif

#if GLOSS_Y_IS_DOWN
#define GLOSS_Y_DIR 1.0
#define GLOSS_ROW_DIR 1
#else
#define GLOSS_Y_DIR -1.0
#define GLOSS_ROW_DIR -1
#endif

float spectrumAt(int band) {
    vec4 packed = iAudioSpectrum[band / 4];
    int lane = band - (band / 4) * 4;
    if (lane == 0) return packed.x;
    if (lane == 1) return packed.y;
    if (lane == 2) return packed.z;
    return packed.w;
}

float rawSpectrumAt(int band) {
    vec4 packed = iAudioSpectrumRaw[band / 4];
    int lane = band - (band / 4) * 4;
    if (lane == 0) return packed.x;
    if (lane == 1) return packed.y;
    if (lane == 2) return packed.z;
    return packed.w;
}

float bandEnergy(int band) {
    return spectrumAt(band);
}

float glyphMaskAt(ivec2 coord) {
    vec4 m = texelFetch(iChannel1, coord, 0);
    return m.a;
}

vec4 backgroundAt(ivec2 coord) {
    return texelFetch(iChannel2, coord, 0);
}

bool isGlyphAt(ivec2 coord) {
    return glyphMaskAt(coord) > 0.001;
}

vec3 rainbowAt(float t) {
    t = clamp(t, 0.0, 1.0);
    vec3 c0 = vec3(0.20, 0.60, 1.00); // blue
    vec3 c1 = vec3(0.20, 1.00, 0.30); // green
    vec3 c2 = vec3(1.00, 0.82, 0.20); // yellow
    vec3 c3 = vec3(1.00, 0.30, 0.20); // red
    if (t < 0.33) return mix(c0, c1, t / 0.33);
    if (t < 0.66) return mix(c1, c2, (t - 0.33) / 0.33);
    return mix(c2, c3, (t - 0.66) / 0.34);
}

float hash12(vec2 p) {
    vec3 p3 = fract(vec3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

int bandForCol(int col, int cols) {
    float t = float(col) / float(max(cols - 1, 1));
    return clamp(int(floor(t * 63.0 + 0.5)), 0, 63);
}

float cellAmp(int row, int col, int rows, int cols, float beat) {
    // Deterministic TS-style mapping: row-major cell index repeats over 64 bands.
    // Group a few cells per band to keep pattern readable and less noisy.
    int char_id = row * max(cols, 1) + col;
    const int chars_per_bucket = 2;
    int band = (char_id / chars_per_bucket) % 64;

    float energy = bandEnergy(band);
    return pow(clamp(energy * 0.92 + beat * 0.22, 0.0, 1.0), 0.82);
}

float cellDy(int row, int col, int rows, int cols, float cell_height, float strength_px, float beat) {
    float amp = cellAmp(row, col, rows, cols, beat);
    float phase = hash12(vec2(float(col) * 1.37, float(row) * 0.73)) * 6.2831853;
    float macro = sin(iTime * 7.0 + float(col) * 0.19) * (0.14 * cell_height * amp);
    float micro = sin(iTime * 10.5 + phase) * (0.18 * cell_height * amp);
    float beat_bounce = smoothstep(0.07, 0.85, clamp(iGlossolalia3.w, 0.0, 1.0)) * cell_height * 0.30;
    float dy = amp * strength_px * 0.72 + macro + micro + beat_bounce;
    return clamp(dy, 0.0, strength_px);
}

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    vec2 pixel = floor(fragCoord);
    float cell_width = max(iCellSize.x, 1.0);
    float cell_height = max(iCellSize.y, 1.0);
    float grid_width = iGridSize.x * cell_width;
    float grid_height = iGridSize.y * cell_height;

    vec2 grid_pos = pixel - iGridPadding;
    if (grid_pos.x < 0.0 || grid_pos.y < 0.0 ||
        grid_pos.x >= grid_width || grid_pos.y >= grid_height) {
        fragColor = texelFetch(iChannel0, ivec2(pixel), 0);
        return;
    }

    int col = int(floor(grid_pos.x / cell_width));
    int row = int(floor(grid_pos.y / cell_height));

    int cols = max(int(iGridSize.x), 1);
    int rows = max(int(iGridSize.y), 1);
    bool debug_bar = iGlossolalia.w > 0.5;

    float beat = clamp(iGlossolalia3.x * 0.6 + iGlossolalia3.y * 0.5, 0.0, 1.0);

    float strength_cells = max(iGlossolalia.x, 0.0);
    float strength_px = strength_cells * cell_height;

    ivec2 base_coord = ivec2(int(pixel.x), int(pixel.y));
    vec4 base = texelFetch(iChannel0, base_coord, 0);
    vec4 base_bg = backgroundAt(base_coord);
    bool drew_glyph = false;
    float amp_for_color = 0.0;
    int max_cells = int(ceil(strength_cells)) + 2;

    // Reverse-map candidate source rows to avoid leaving stale glyphs behind.
    for (int offset = 0; offset <= max_cells && !drew_glyph; offset++) {
        int src_row = row + GLOSS_ROW_DIR * offset;
        if (src_row < 0 || src_row >= rows) continue;

        float src_amp = cellAmp(src_row, col, rows, cols, beat);
        float src_dy = cellDy(src_row, col, rows, cols, cell_height, strength_px, beat);
        float y_in = pixel.y + GLOSS_Y_DIR * src_dy;

        float cell_y0 = iGridPadding.y + float(src_row) * cell_height;
        float cell_y1 = cell_y0 + cell_height;
        if (y_in < cell_y0 || y_in >= cell_y1) continue;

        ivec2 sample_coord = ivec2(int(pixel.x), int(y_in));
        sample_coord.x = clamp(sample_coord.x, 0, int(iResolution.x) - 1);
        sample_coord.y = clamp(sample_coord.y, 0, int(iResolution.y) - 1);
        if (!isGlyphAt(sample_coord)) continue;

        fragColor = texelFetch(iChannel0, sample_coord, 0);
        drew_glyph = true;
        amp_for_color = src_amp;
    }

    if (!drew_glyph) {
        if (isGlyphAt(base_coord)) {
            fragColor = base_bg;
        } else {
            fragColor = base;
        }
    }

    float color_mod = iGlossolalia2.y;
    bool glyph_for_color = drew_glyph;
    if (color_mod > 0.0 && glyph_for_color) {
        float tint_energy = drew_glyph ? max(amp_for_color, beat * 0.6) : 0.0;
        vec3 tint_color = rainbowAt(tint_energy);
        // Keep baseline glyph color unchanged and only blend in color on energy peaks.
        float tint = clamp(color_mod * smoothstep(0.10, 0.95, tint_energy), 0.0, 0.85);
        fragColor.rgb = clamp(mix(fragColor.rgb, tint_color, tint), 0.0, 1.0);
    }

    // Background spectrum overlay — behind text, across full grid
    if (debug_bar && !drew_glyph) {
        // Smooth band interpolation (no column stepping)
        float fx = grid_pos.x / grid_width * 63.0;
        int b0 = clamp(int(floor(fx)), 0, 63);
        int b1 = clamp(b0 + 1, 0, 63);
        float bf = fract(fx);

        float energy = mix(bandEnergy(b0), bandEnergy(b1), bf);
        float raw_gain = max(iGlossolalia2.z, 1.0);
        float raw_e = pow(clamp(mix(rawSpectrumAt(b0), rawSpectrumAt(b1), bf) * raw_gain, 0.0, 1.0), 0.7);

        // Floor gate: fade out in quiet sections (no permanent haze)
        float floor_gate = smoothstep(0.05, 0.16, energy);
        float raw_gate = smoothstep(0.06, 0.18, raw_e);

        float vy = 1.0 - grid_pos.y / grid_height; // 0=bottom, 1=top
        float band_t = fx / 63.0;

        // Processed energy: soft glow rising from bottom
        float gh = energy * 0.5;
        float glow = smoothstep(gh, 0.0, vy);
        glow = glow * glow * energy * floor_gate;

        // Raw spectrum: ghost peak-line with tighter halo
        float rh = raw_e * 0.5;
        float ghost = exp(-pow((vy - rh) * 72.0, 2.0))
                     + exp(-pow((vy - rh) * 18.0, 2.0)) * 0.18;
        ghost *= raw_gate;

        // Muted rainbow for processed, cool blue for raw ghost
        vec3 g_col = mix(vec3(0.12), rainbowAt(band_t), 0.65);
        vec3 r_col = vec3(0.45, 0.65, 1.0);

        // Pulse from kick/snare only (short attack, fast decay)
        float kick_snare = clamp(iGlossolalia3.x + iGlossolalia3.y * 0.7, 0.0, 1.0);
        float pulse = smoothstep(0.0, 0.5, kick_snare) * 0.04;

        fragColor.rgb += g_col * glow * 0.18 + r_col * ghost * 0.15 + pulse;
        fragColor.rgb = clamp(fragColor.rgb, 0.0, 1.0);
    }
}
