/*
 * netsurf_render frontend: offscreen renderer for the goodreadskosync plugin.
 *
 * Renders a URL into an in-memory ARGB buffer (never /dev/fb0) and dumps
 * frame.pgm + hits.json. Built alongside NetSurf's core.
 */

#ifndef NS_RENDER_H
#define NS_RENDER_H

#include <stdint.h>
#include "netsurf/plotters.h"

/* Window size used by the frontend's gui_window_create. */
extern int render_default_width;
extern int render_default_height;

/* Offscreen framebuffer (ARGB, 0xAARRGGBB). */
void render_alloc(int w, int h);
uint32_t *render_pixels(void);
int render_pixel_width(void);
int render_pixel_height(void);
void render_clear(colour c);

struct render_opts {
	const char *url;
	int width;
	int height;
	int scroll;
	const char *out;
	const char *cookies;
};

/* Returns 1 if render mode was requested (and fills opts). Strips the
 * render-specific options from argv so NetSurf's parser does not see them. */
int render_parse_args(int *argcp, char **argv, struct render_opts *opts);

/* Bitmap accessors implemented by this frontend's bitmap.c. */
struct bitmap;
unsigned char *render_bitmap_buffer(struct bitmap *bm);
int render_bitmap_width(struct bitmap *bm);
int render_bitmap_height(struct bitmap *bm);
size_t render_bitmap_rowstride(struct bitmap *bm);

/* Runs one render and writes the outputs. Returns process exit code. */
int render_main(const struct render_opts *opts);

#endif
