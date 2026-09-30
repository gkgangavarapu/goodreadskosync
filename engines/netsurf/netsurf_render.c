/*
 * netsurf_render — offscreen NetSurf render helper for the goodreadskosync
 * KOReader plugin's BrowserEngine contract.
 *
 * It renders a page into an libnsfb MEMORY surface (never /dev/fb0), converts
 * the surface to an 8-bit grayscale PGM frame, and writes a JSON hitmap:
 *
 *     netsurf_render --url URL --width W --height H --scroll Y --out PREFIX
 *
 * Outputs PREFIX.pgm (P5, W*H bytes) and PREFIX.json.
 *
 * Build modes:
 *   (default)            plumbing only — draws a placeholder frame so the
 *                        protocol, PGM writer and Lua adapter can be tested
 *                        before the NetSurf core is linked in.
 *   -DHAVE_NETSURF       link NetSurf's core and render the real page. The
 *                        integration points are marked NETSURF-INTEGRATION and
 *                        depend on the exact NetSurf revision (its embedding API
 *                        is not stable).
 *
 * Safety: this program must never open /dev/fb0. The surface is allocated in
 * process memory by libnsfb's "mem" surface.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

#ifdef HAVE_NETSURF
#include <libnsfb.h>
#include <libnsfb_plot.h>
#endif

#define DEFAULT_WIDTH  600
#define DEFAULT_HEIGHT 800

struct options {
    const char *url;
    const char *out;
    const char *cookies;
    int width;
    int height;
    int scroll_y;
};

/* ------------------------------------------------------------------ output */

static void json_escape(FILE *f, const char *s)
{
    if (!s) return;
    for (; *s; s++) {
        unsigned char c = (unsigned char)*s;
        switch (c) {
        case '"':  fputs("\\\"", f); break;
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

struct hit {
    int x, y, w, h;
    char *href;
};

static int write_pgm(const char *prefix, const uint8_t *gray, int w, int h)
{
    char path[4096];
    snprintf(path, sizeof(path), "%s.pgm", prefix);
    FILE *f = fopen(path, "wb");
    if (!f) { perror(path); return -1; }
    fprintf(f, "P5\n%d %d\n255\n", w, h);
    if (fwrite(gray, 1, (size_t)w * (size_t)h, f) != (size_t)w * (size_t)h) {
        fclose(f);
        return -1;
    }
    fclose(f);
    return 0;
}

static int write_json(const char *prefix, const struct options *o,
                      const char *url, const char *title,
                      int w, int h, int scroll_h, int scroll_y,
                      const struct hit *hits, int n_hits)
{
    char path[4096];
    snprintf(path, sizeof(path), "%s.json", prefix);
    FILE *f = fopen(path, "wb");
    if (!f) { perror(path); return -1; }

    fputs("{\"url\":\"", f); json_escape(f, url);
    fputs("\",\"title\":\"", f); json_escape(f, title);
    fprintf(f, "\",\"width\":%d,\"height\":%d,", w, h);
    fprintf(f, "\"scroll_h\":%d,\"scroll_y\":%d,\"hits\":[", scroll_h, scroll_y);
    for (int i = 0; i < n_hits; i++) {
        if (i) fputc(',', f);
        fprintf(f, "{\"x\":%d,\"y\":%d,\"w\":%d,\"h\":%d,\"href\":\"",
                hits[i].x, hits[i].y, hits[i].w, hits[i].h);
        json_escape(f, hits[i].href ? hits[i].href : "");
        fputs("\"}", f);
    }
    fputs("]}", f);
    fclose(f);
    (void)o;
    return 0;
}

#ifdef HAVE_NETSURF
/* ------------------------------------------------------- libnsfb mem surface */

/*
 * Allocate an offscreen ARGB surface and blit it to 8-bit grayscale.
 * libnsfb's memory surface lives entirely in process memory.
 */
static int render_with_netsurf(const struct options *o, uint8_t **out_gray,
                               int *out_scroll_h, struct hit **out_hits,
                               int *out_hits_n, char **out_title)
{
    nsfb_t *nsfb = nsfb_init(NSFB_SURFACE_MEM);
    if (!nsfb) { fprintf(stderr, "nsfb_init(mem) failed\n"); return -1; }
    if (nsfb_init_frontend(nsfb) != 0) {
        fprintf(stderr, "nsfb_init_frontend failed\n"); return -1;
    }
    if (nsfb_set_geometry(nsfb, o->width, o->height, NSFB_FMT_ABGR8888) != 0) {
        fprintf(stderr, "nsfb_set_geometry failed\n"); return -1;
    }

    uint8_t *pixels = NULL;
    int stride = 0;
    if (nsfb_get_buffer(nsfb, &pixels, &stride) != 0 || !pixels) {
        fprintf(stderr, "nsfb_get_buffer failed\n"); return -1;
    }
    nsfb_claim(nsfb, NULL);

    /*
     * NETSURF-INTEGRATION
     * -------------------
     * Drive NetSurf's core against this surface:
     *   1. netsurf_init(...) with a gui_table whose plot callbacks draw into
     *      `nsfb` (see NetSurf's frontends/ for the gui_window/gui_table API).
     *   2. browser_window_create(o->url, &bw, NULL, true, false);
     *   3. run the event loop until the content's status is CONTENT_STATUS_DONE
     *      (or a timeout), pumping nsfb updates between iterations.
     *   4. read title/url/scroll height from the browser window and content.
     *   5. walk the HTML box tree for anchor boxes to fill the hitmap.
     * This block is revision-specific and must be finished on the build machine
     * against the exact NetSurf checkout (its embedding API is not stable).
     */
    fprintf(stderr, "HAVE_NETSURF build: NetSurf core integration not yet wired "
                    "(see NETSURF-INTEGRATION)\n");
    nsfb_release(nsfb);
    nsfb_free(nsfb);
    (void)out_gray; (void)out_scroll_h; (void)out_hits;
    (void)out_hits_n; (void)out_title;
    return -1;
}
#else
/* ------------------------------------------------------------- placeholder */

/* Draws a simple gradient so the protocol/PGM path can be exercised. */
static int render_placeholder(const struct options *o, uint8_t **out_gray)
{
    int w = o->width, h = o->height;
    uint8_t *gray = malloc((size_t)w * (size_t)h);
    if (!gray) return -1;
    for (int y = 0; y < h; y++) {
        for (int x = 0; x < w; x++) {
            int v = (x * 255) / (w > 1 ? w - 1 : 1);
            int band = ((y / 40) % 2) ? 24 : 0;
            int g = v / 2 + band;
            if (g > 255) g = 255;
            gray[y * w + x] = (uint8_t)g;
        }
    }
    *out_gray = gray;
    return 0;
}
#endif

/* -------------------------------------------------------------------- main */

static void usage(const char *argv0)
{
    fprintf(stderr,
        "usage: %s --url URL --width W --height H --scroll Y --out PREFIX "
        "[--cookies FILE]\n", argv0);
}

static int parse_args(int argc, char **argv, struct options *o)
{
    o->url = NULL; o->out = NULL; o->cookies = NULL;
    o->width = DEFAULT_WIDTH; o->height = DEFAULT_HEIGHT; o->scroll_y = 0;

    for (int i = 1; i < argc; i++) {
        const char *a = argv[i];
        const char *v = (i + 1 < argc) ? argv[i + 1] : NULL;
        if (!strcmp(a, "--url") && v) { o->url = v; i++; }
        else if (!strcmp(a, "--out") && v) { o->out = v; i++; }
        else if (!strcmp(a, "--cookies") && v) { o->cookies = v; i++; }
        else if (!strcmp(a, "--width") && v) { o->width = atoi(v); i++; }
        else if (!strcmp(a, "--height") && v) { o->height = atoi(v); i++; }
        else if (!strcmp(a, "--scroll") && v) { o->scroll_y = atoi(v); i++; }
        else { fprintf(stderr, "unknown arg: %s\n", a); return -1; }
    }
    if (!o->url || !o->out) return -1;
    if (o->width <= 0 || o->height <= 0) return -1;
    if (o->scroll_y < 0) o->scroll_y = 0;
    return 0;
}

int main(int argc, char **argv)
{
    struct options o;
    if (parse_args(argc, argv, &o) != 0) { usage(argv[0]); return 2; }

    uint8_t *gray = NULL;
    int scroll_h = o.height;
    struct hit *hits = NULL;
    int n_hits = 0;
    char *title = NULL;

#ifdef HAVE_NETSURF
    if (render_with_netsurf(&o, &gray, &scroll_h, &hits, &n_hits, &title) != 0) {
        return 1;
    }
#else
    if (render_placeholder(&o, &gray) != 0) return 1;
#endif

    if (write_pgm(o.out, gray, o.width, o.height) != 0) { free(gray); return 1; }
    if (write_json(o.out, &o, o.url, title ? title : "",
                   o.width, o.height, scroll_h, o.scroll_y,
                   hits, n_hits) != 0) {
        free(gray);
        return 1;
    }

    free(gray);
    free(title);
    for (int i = 0; i < n_hits; i++) free(hits[i].href);
    free(hits);
    return 0;
}
