/*
 * One-shot offscreen render for the goodreadskosync NetSurf engine.
 *
 * Loads a URL, runs NetSurf's event loop until the page is done, redraws the
 * page into the in-memory framebuffer, and writes frame.pgm + frame.json.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <sys/select.h>
#include <sys/time.h>
#include <unistd.h>

#include "utils/log.h"
#include "utils/nsurl.h"
#include "utils/nsoption.h"

#include "netsurf/netsurf.h"
#include "netsurf/browser_window.h"
#include "netsurf/bitmap.h"
#include "netsurf/content.h"
#include "netsurf/url_db.h"
#include "netsurf/cookie_db.h"
#include "netsurf/content_type.h"
#include "netsurf/types.h"

#include <dom/dom.h>

#include "content/fetch.h"
#include "content/content.h"
#include "content/hlcache.h"
#include "content/handlers/html/box.h"
#include "content/handlers/html/html_save.h"

#include "monkey/browser.h"
#include "monkey/schedule.h"
#include "monkey/plot.h"
#include "monkey/render.h"

int render_default_width = 800;
int render_default_height = 600;

static int is_render_opt(const char *a)
{
	return (!strcmp(a, "--out") || !strcmp(a, "--url") ||
		!strcmp(a, "--width") || !strcmp(a, "--height") ||
		!strcmp(a, "--scroll") || !strcmp(a, "--cookies"));
}

int render_parse_args(int *argcp, char **argv, struct render_opts *o)
{
	int argc = *argcp, i, n = 1, found = 0;

	o->url = NULL; o->out = NULL; o->cookies = NULL;
	o->width = 0; o->height = 0; o->scroll = 0;

	for (i = 1; i < argc; i++) {
		if (!strcmp(argv[i], "--out") && i + 1 < argc) { o->out = argv[i + 1]; found = 1; }
		else if (!strcmp(argv[i], "--url") && i + 1 < argc) { o->url = argv[i + 1]; }
		else if (!strcmp(argv[i], "--width") && i + 1 < argc) { o->width = atoi(argv[i + 1]); }
		else if (!strcmp(argv[i], "--height") && i + 1 < argc) { o->height = atoi(argv[i + 1]); }
		else if (!strcmp(argv[i], "--scroll") && i + 1 < argc) { o->scroll = atoi(argv[i + 1]); }
		else if (!strcmp(argv[i], "--cookies") && i + 1 < argc) { o->cookies = argv[i + 1]; }
	}

	if (!found) return 0;

	if (o->width <= 0) o->width = 600;
	if (o->height <= 0) o->height = 800;
	if (o->url == NULL) o->url = "about:blank";
	if (o->scroll < 0) o->scroll = 0;

	/* Strip our options so NetSurf's option parser does not see them. */
	for (i = 1; i < argc; i++) {
		if (is_render_opt(argv[i])) { i++; continue; }
		argv[n++] = argv[i];
	}
	argv[n] = NULL;
	*argcp = n;

	return 1;
}

static void json_escape(FILE *f, const char *s)
{
	if (s == NULL) return;
	for (; *s; s++) {
		unsigned char c = (unsigned char)*s;
		switch (c) {
		case '"': fputs("\\\"", f); break;
		case '\\': fputs("\\\\", f); break;
		case '\n': fputs("\\n", f); break;
		case '\r': fputs("\\r", f); break;
		case '\t': fputs("\\t", f); break;
		default:
			if (c < 0x20) fprintf(f, "\\u%04x", c);
			else fputc(c, f);
		}
	}
}

static int write_pgm(const char *prefix)
{
	char path[4096];
	uint32_t *px = render_pixels();
	int w = render_pixel_width(), h = render_pixel_height();
	FILE *f;
	int i;

	if (px == NULL) return -1;
	snprintf(path, sizeof(path), "%s.pgm", prefix);
	f = fopen(path, "wb");
	if (f == NULL) { perror(path); return -1; }
	fprintf(f, "P5\n%d %d\n255\n", w, h);
	{
		unsigned char *gray = malloc((size_t)w * h);
		if (gray == NULL) { fclose(f); return -1; }
		for (i = 0; i < w * h; i++) {
			unsigned r = (px[i] >> 16) & 0xff;
			unsigned g = (px[i] >> 8) & 0xff;
			unsigned b = px[i] & 0xff;
			gray[i] = (unsigned char)((77 * r + 151 * g + 28 * b) >> 8);
		}
		if (fwrite(gray, 1, (size_t)w * h, f) != (size_t)w * h) { free(gray); fclose(f); return -1; }
		free(gray);
	}
	fclose(f);
	return 0;
}

static void collect_links(struct box *b, int ox, int oy, int scroll,
		int vw, int vh, FILE *f, int *count)
{
	for (; b != NULL; b = b->next) {
		int x = ox + b->x;
		int y = oy + b->y;
		if (b->href != NULL && b->width > 0 && b->height > 0) {
			int hx = x, hy = y - scroll;
			if (hx < vw && hx + b->width > 0 && hy < vh && hy + b->height > 0) {
				const char *u = nsurl_access(b->href);
				if (u != NULL) {
					if (*count > 0) fputc(',', f);
					fprintf(f, "{\"x\":%d,\"y\":%d,\"w\":%d,\"h\":%d,\"href\":\"",
						hx, hy, b->width, b->height);
					json_escape(f, u);
					fputs("\"}", f);
					(*count)++;
				}
			}
		}
		if (b->children != NULL)
			collect_links(b->children, x, y, scroll, vw, vh, f, count);
		if (b->float_children != NULL)
			collect_links(b->float_children, x, y, scroll, vw, vh, f, count);
	}
}

static int write_json(const struct render_opts *o, struct gui_window *gw)
{
	char path[4096];
	FILE *f;
	char urlbuf[2048] = "";
	const char *title = "";
	int count = 0, ew = 0, eh = 0;
	struct nsurl *url = NULL;
	struct hlcache_handle *h;

	snprintf(path, sizeof(path), "%s.json", o->out);
	f = fopen(path, "wb");
	if (f == NULL) { perror(path); return -1; }

	if (browser_window_get_url(gw->bw, false, &url) == NSERROR_OK && url != NULL) {
		snprintf(urlbuf, sizeof(urlbuf), "%s", nsurl_access(url));
		nsurl_unref(url);
	}
	title = browser_window_get_title(gw->bw);
	if (title == NULL) title = "";
	if (browser_window_get_extents(gw->bw, false, &ew, &eh) != NSERROR_OK) {
		ew = o->width; eh = o->height;
	}

	fputs("{\"url\":\"", f); json_escape(f, urlbuf);
	fputs("\",\"title\":\"", f); json_escape(f, title);
	fprintf(f, "\",\"width\":%d,\"height\":%d,", o->width, o->height);
	fprintf(f, "\"scroll_h\":%d,\"scroll_y\":%d,\"hits\":[", eh, o->scroll);

	h = browser_window_get_content(gw->bw);
	/* Only HTML content has a box tree; other content types would crash. */
	if (h != NULL && content_get_type(h) == CONTENT_HTML) {
		struct box *root = html_get_box_tree(h);
		if (root != NULL)
			collect_links(root, 0, 0, o->scroll, o->width, o->height, f, &count);
	}

	fputs("]}", f);
	fclose(f);
	return 0;
}

int render_main(const struct render_opts *o)
{
	static const bitmap_fmt_t fmt = { BITMAP_LAYOUT_R8G8B8A8, false };
	nsurl *url = NULL;
	struct gui_window *gw;
	struct redraw_context ctx;
	struct rect clip;
	time_t start;
	int done = 0, settle = 0;

	render_default_width = o->width;
	render_default_height = o->height;
	bitmap_set_format(&fmt);

	if (o->cookies != NULL && o->cookies[0] != '\0') {
		nsoption_setnull_charp(cookie_file, strdup(o->cookies));
		nsoption_setnull_charp(cookie_jar, strdup(o->cookies));
		urldb_load_cookies(o->cookies);
	}

	render_alloc(o->width, o->height);
	render_clear(0xffffff);

	if (nsurl_create(o->url, &url) != NSERROR_OK) {
		fprintf(stderr, "netsurf_render: bad url %s\n", o->url);
		return 1;
	}
	if (browser_window_create(BW_CREATE_HISTORY, url, NULL, NULL, NULL) != NSERROR_OK) {
		fprintf(stderr, "netsurf_render: window create failed\n");
		nsurl_unref(url);
		return 1;
	}
	nsurl_unref(url);

	gw = monkey_find_window_by_num(0);
	if (gw == NULL) {
		fprintf(stderr, "netsurf_render: no gui window\n");
		return 1;
	}

	start = time(NULL);
	for (;;) {
		int sched = monkey_schedule_run();
		fd_set r, w, e;
		int maxfd = -1;
		struct timeval tv;
		struct timeval *to = &tv;
		struct hlcache_handle *h;

		fetch_fdset(&r, &w, &e, &maxfd);
		if (maxfd < 0) maxfd = 0;

		if (sched < 0) { tv.tv_sec = 0; tv.tv_usec = 50000; }
		else {
			tv.tv_sec = sched / 1000;
			tv.tv_usec = (sched % 1000) * 1000;
			if (tv.tv_sec > 0 || tv.tv_usec > 50000) { tv.tv_sec = 0; tv.tv_usec = 50000; }
		}
		select(maxfd + 1, &r, &w, &e, to);

		h = browser_window_get_content(gw->bw);
		if (h != NULL && content_get_status(h) == CONTENT_STATUS_DONE) done = 1;
		if (done) {
			settle++;
			if (maxfd == 0 && settle > 3) break;
		}
		if (time(NULL) - start > 30) break;
	}

	render_clear(0xffffff);
	memset(&ctx, 0, sizeof(ctx));
	ctx.interactive = true;
	ctx.background_images = true;
	ctx.plot = monkey_plotters;
	clip.x0 = 0; clip.y0 = 0; clip.x1 = o->width; clip.y1 = o->height;
	if (!browser_window_redraw(gw->bw, 0, o->scroll, &clip, &ctx)) {
		fprintf(stderr, "netsurf_render: redraw not ready\n");
	}

	if (write_pgm(o->out) != 0) return 1;
	if (write_json(o, gw) != 0) return 1;
	return 0;
}
