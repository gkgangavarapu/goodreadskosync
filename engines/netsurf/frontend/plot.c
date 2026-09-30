/*
 * Memory-buffer plotter for the offscreen NetSurf renderer.
 *
 * Replaces NetSurf's monkey text plotter: every plot op is rasterised into a
 * 32bpp ARGB buffer (0xAARRGGBB) that the renderer converts to 8-bit grayscale.
 * Text uses an embedded public-domain 8x8 font.
 */

#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "utils/utils.h"
#include "utils/errors.h"
#include "netsurf/plotters.h"
#include "netsurf/bitmap.h"

#include "monkey/render.h"
#include "font8x8_basic.h"

static uint32_t *fb_pixels = NULL;
static int fb_w = 0, fb_h = 0;
static int clip_x0 = 0, clip_y0 = 0, clip_x1 = 0, clip_y1 = 0;

void render_alloc(int w, int h)
{
	fb_w = w;
	fb_h = h;
	free(fb_pixels);
	fb_pixels = calloc((size_t)w * (size_t)h, sizeof(uint32_t));
	clip_x0 = 0; clip_y0 = 0; clip_x1 = w; clip_y1 = h;
}

uint32_t *render_pixels(void) { return fb_pixels; }
int render_pixel_width(void) { return fb_w; }
int render_pixel_height(void) { return fb_h; }

void render_clear(colour c)
{
	uint32_t v = 0xff000000u | ((c & 0xff) << 16) |
		(((c >> 8) & 0xff) << 8) | ((c >> 16) & 0xff);
	long n;
	if (fb_pixels == NULL) return;
	for (n = 0; n < (long)fb_w * fb_h; n++) fb_pixels[n] = v;
}

static inline uint32_t nscolour_to_argb(colour c)
{
	return 0xff000000u | ((c & 0xff) << 16) |
		(((c >> 8) & 0xff) << 8) | ((c >> 16) & 0xff);
}

static inline void put(int x, int y, uint32_t argb)
{
	if (fb_pixels == NULL) return;
	if (x < clip_x0 || x >= clip_x1 || y < clip_y0 || y >= clip_y1) return;
	if (x < 0 || y < 0 || x >= fb_w || y >= fb_h) return;
	fb_pixels[(size_t)y * fb_w + x] = argb;
}

static inline void blend(int x, int y, uint32_t rgb, unsigned a)
{
	uint32_t d;
	if (fb_pixels == NULL) return;
	if (x < clip_x0 || x >= clip_x1 || y < clip_y0 || y >= clip_y1) return;
	if (x < 0 || y < 0 || x >= fb_w || y >= fb_h) return;
	d = fb_pixels[(size_t)y * fb_w + x];
	{
		unsigned dr = (d >> 16) & 0xff, dg = (d >> 8) & 0xff, db = d & 0xff;
		unsigned sr = (rgb >> 16) & 0xff, sg = (rgb >> 8) & 0xff, sb = rgb & 0xff;
		unsigned r = (sr * a + dr * (255 - a)) / 255;
		unsigned g = (sg * a + dg * (255 - a)) / 255;
		unsigned b = (sb * a + db * (255 - a)) / 255;
		fb_pixels[(size_t)y * fb_w + x] = 0xff000000u | (r << 16) | (g << 8) | b;
	}
}

static void draw_glyph(int x, int y, int px, uint32_t col, unsigned char ch)
{
	const char *g = font8x8_basic[ch & 0x7f];
	int dx, dy;
	if (px < 1) px = 1;
	for (dy = 0; dy < px; dy++) {
		int sy = dy * 8 / px;
		unsigned char bits = (unsigned char)g[sy];
		for (dx = 0; dx < px; dx++) {
			int sx = dx * 8 / px;
			if (bits & (1 << sx)) put(x + dx, y + dy, col);
		}
	}
}

static nserror plot_clip(const struct redraw_context *ctx, const struct rect *clip)
{
	(void)ctx;
	clip_x0 = clip->x0 < 0 ? 0 : clip->x0;
	clip_y0 = clip->y0 < 0 ? 0 : clip->y0;
	clip_x1 = clip->x1 > fb_w ? fb_w : clip->x1;
	clip_y1 = clip->y1 > fb_h ? fb_h : clip->y1;
	return NSERROR_OK;
}

static nserror plot_arc(const struct redraw_context *ctx, const plot_style_t *style,
		int x, int y, int radius, int angle1, int angle2)
{
	(void)ctx; (void)style; (void)x; (void)y; (void)radius; (void)angle1; (void)angle2;
	return NSERROR_OK;
}

static nserror plot_disc(const struct redraw_context *ctx, const plot_style_t *style,
		int x, int y, int radius)
{
	int dx, dy;
	uint32_t col;
	(void)ctx;
	if (style->fill_type == PLOT_OP_TYPE_NONE || style->fill_colour == NS_TRANSPARENT)
		return NSERROR_OK;
	col = nscolour_to_argb(style->fill_colour);
	for (dy = -radius; dy <= radius; dy++) {
		for (dx = -radius; dx <= radius; dx++) {
			if (dx * dx + dy * dy <= radius * radius) put(x + dx, y + dy, col);
		}
	}
	return NSERROR_OK;
}

static nserror plot_line(const struct redraw_context *ctx, const plot_style_t *style,
		const struct rect *line)
{
	int x0 = line->x0, y0 = line->y0, x1 = line->x1, y1 = line->y1;
	int dx, dy, sx, sy, err, e2, t, k;
	uint32_t col;
	(void)ctx;
	if (style->stroke_type == PLOT_OP_TYPE_NONE || style->stroke_colour == NS_TRANSPARENT)
		return NSERROR_OK;
	col = nscolour_to_argb(style->stroke_colour);
	t = plot_style_fixed_to_int(style->stroke_width);
	if (t < 1) t = 1;
	dx = abs(x1 - x0); sx = x0 < x1 ? 1 : -1;
	dy = -abs(y1 - y0); sy = y0 < y1 ? 1 : -1;
	err = dx + dy;
	for (;;) {
		for (k = 0; k < t; k++) put(x0, y0 + k, col);
		if (x0 == x1 && y0 == y1) break;
		e2 = 2 * err;
		if (e2 >= dy) { err += dy; x0 += sx; }
		if (e2 <= dx) { err += dx; y0 += sy; }
	}
	return NSERROR_OK;
}

static nserror plot_rectangle(const struct redraw_context *ctx, const plot_style_t *style,
		const struct rect *rect)
{
	int x, y, k, t;
	uint32_t col;
	(void)ctx;
	if (style->fill_type != PLOT_OP_TYPE_NONE && style->fill_colour != NS_TRANSPARENT) {
		col = nscolour_to_argb(style->fill_colour);
		for (y = rect->y0; y < rect->y1; y++)
			for (x = rect->x0; x < rect->x1; x++) put(x, y, col);
	}
	if (style->stroke_type != PLOT_OP_TYPE_NONE && style->stroke_colour != NS_TRANSPARENT) {
		col = nscolour_to_argb(style->stroke_colour);
		t = plot_style_fixed_to_int(style->stroke_width);
		if (t < 1) t = 1;
		for (y = rect->y0; y < rect->y1; y++)
			for (k = 0; k < t; k++) { put(rect->x0 + k, y, col); put(rect->x1 - 1 - k, y, col); }
		for (x = rect->x0; x < rect->x1; x++)
			for (k = 0; k < t; k++) { put(x, rect->y0 + k, col); put(x, rect->y1 - 1 - k, col); }
	}
	return NSERROR_OK;
}

static nserror plot_polygon(const struct redraw_context *ctx, const plot_style_t *style,
		const int *p, unsigned int n)
{
	(void)ctx; (void)style; (void)p; (void)n;
	return NSERROR_OK;
}

static nserror plot_path(const struct redraw_context *ctx, const plot_style_t *style,
		const float *p, unsigned int n, const float transform[6])
{
	(void)ctx; (void)style; (void)p; (void)n; (void)transform;
	return NSERROR_OK;
}

static nserror plot_bitmap(const struct redraw_context *ctx, struct bitmap *bitmap,
		int x, int y, int width, int height, colour bg, bitmap_flags_t flags)
{
	unsigned char *buf;
	int bw, bh, dx, dy;
	size_t stride;
	(void)ctx; (void)bg; (void)flags;
	if (bitmap == NULL) return NSERROR_OK;
	buf = render_bitmap_buffer(bitmap);
	bw = render_bitmap_width(bitmap);
	bh = render_bitmap_height(bitmap);
	stride = render_bitmap_rowstride(bitmap);
	if (buf == NULL || bw <= 0 || bh <= 0 || width <= 0 || height <= 0) return NSERROR_OK;
	for (dy = 0; dy < height; dy++) {
		int sy = dy * bh / height;
		for (dx = 0; dx < width; dx++) {
			int sx = dx * bw / width;
			unsigned char *sp = buf + (size_t)sy * stride + (size_t)sx * 4;
			unsigned r = sp[0], g = sp[1], b = sp[2], a = sp[3];
			uint32_t rgb;
			if (a == 0) continue;
			rgb = (r << 16) | (g << 8) | b;
			if (a == 255) put(x + dx, y + dy, 0xff000000u | rgb);
			else blend(x + dx, y + dy, rgb, a);
		}
	}
	return NSERROR_OK;
}

static nserror plot_text(const struct redraw_context *ctx, const plot_font_style_t *fstyle,
		int x, int y, const char *text, size_t length)
{
	int px, ty, cx, bold;
	size_t i = 0;
	uint32_t col;
	(void)ctx;
	px = plot_style_fixed_to_int(fstyle->size);
	if (px < 6) px = 6;
	if (px > 64) px = 64;
	col = nscolour_to_argb(fstyle->foreground);
	bold = (fstyle->weight >= 600);
	ty = y - px;              /* NetSurf gives the baseline */
	if (ty < -px) ty = y - px;
	cx = x;
	while (i < length) {
		unsigned char c = (unsigned char)text[i];
		uint32_t cp;
		unsigned char g;
		if (c < 0x80) { cp = c; i += 1; }
		else if ((c & 0xE0) == 0xC0 && i + 1 < length) {
			cp = ((c & 0x1f) << 6) | (text[i + 1] & 0x3f); i += 2;
		} else if ((c & 0xF0) == 0xE0 && i + 2 < length) {
			cp = ((c & 0x0f) << 12) | ((text[i + 1] & 0x3f) << 6) | (text[i + 2] & 0x3f); i += 3;
		} else if ((c & 0xF8) == 0xF0 && i + 3 < length) {
			i += 4; cp = '?';
		} else { i += 1; cp = '?'; }
		g = (cp >= 32 && cp < 127) ? (unsigned char)cp : '?';
		draw_glyph(cx, ty, px, col, g);
		if (bold) draw_glyph(cx + 1, ty, px, col, g);
		cx += px;
	}
	return NSERROR_OK;
}

static const struct plotter_table plotters = {
	.clip = plot_clip,
	.arc = plot_arc,
	.disc = plot_disc,
	.line = plot_line,
	.rectangle = plot_rectangle,
	.polygon = plot_polygon,
	.path = plot_path,
	.bitmap = plot_bitmap,
	.text = plot_text,
	.option_knockout = true,
};

const struct plotter_table *monkey_plotters = &plotters;
