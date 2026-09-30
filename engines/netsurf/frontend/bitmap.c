/*
 * Monkey frontend bitmap implementation, extended with accessors used by the
 * offscreen plotter. Bitmaps are plain 32bpp buffers allocated with malloc;
 * the pixel layout is set by the frontend via bitmap_set_format().
 */

#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <stddef.h>

#include "utils/errors.h"
#include "netsurf/bitmap.h"

#include "monkey/output.h"
#include "monkey/bitmap.h"
#include "monkey/render.h"

struct bitmap {
	void *ptr;
	size_t rowstride;
	int width;
	int height;
	bool opaque;
};

unsigned char *render_bitmap_buffer(struct bitmap *bm)
{
	return (bm == NULL) ? NULL : (unsigned char *)bm->ptr;
}

int render_bitmap_width(struct bitmap *bm)
{
	return (bm == NULL) ? 0 : bm->width;
}

int render_bitmap_height(struct bitmap *bm)
{
	return (bm == NULL) ? 0 : bm->height;
}

size_t render_bitmap_rowstride(struct bitmap *bm)
{
	return (bm == NULL) ? 0 : bm->rowstride;
}

static void *bitmap_create(int width, int height, enum gui_bitmap_flags flags)
{
	struct bitmap *ret = calloc(sizeof(*ret), 1);
	if (ret == NULL)
		return NULL;

	ret->width = width;
	ret->height = height;
	ret->opaque = (flags & BITMAP_OPAQUE) == BITMAP_OPAQUE;
	ret->rowstride = (size_t)width * 4;
	ret->ptr = calloc((size_t)width, (size_t)height * 4);

	if (ret->ptr == NULL) {
		free(ret);
		return NULL;
	}

	return ret;
}

static void bitmap_destroy(void *bitmap)
{
	struct bitmap *bmap = bitmap;
	free(bmap->ptr);
	free(bmap);
}

static void bitmap_set_opaque(void *bitmap, bool opaque)
{
	struct bitmap *bmap = bitmap;
	bmap->opaque = opaque;
}

static bool bitmap_get_opaque(void *bitmap)
{
	struct bitmap *bmap = bitmap;
	return bmap->opaque;
}

static unsigned char *bitmap_get_buffer(void *bitmap)
{
	struct bitmap *bmap = bitmap;
	return (unsigned char *)(bmap->ptr);
}

static size_t bitmap_get_rowstride(void *bitmap)
{
	struct bitmap *bmap = bitmap;
	return bmap->rowstride;
}

static void bitmap_modified(void *bitmap)
{
	(void)bitmap;
}

static int bitmap_get_width(void *bitmap)
{
	struct bitmap *bmap = bitmap;
	return bmap->width;
}

static int bitmap_get_height(void *bitmap)
{
	struct bitmap *bmap = bitmap;
	return bmap->height;
}

static nserror bitmap_render(struct bitmap *bitmap, struct hlcache_handle *content)
{
	(void)bitmap; (void)content;
	moutf(MOUT_GENERIC, "BITMAP RENDER");
	return NSERROR_OK;
}

static struct gui_bitmap_table bitmap_table = {
	.create = bitmap_create,
	.destroy = bitmap_destroy,
	.set_opaque = bitmap_set_opaque,
	.get_opaque = bitmap_get_opaque,
	.get_buffer = bitmap_get_buffer,
	.get_rowstride = bitmap_get_rowstride,
	.get_width = bitmap_get_width,
	.get_height = bitmap_get_height,
	.modified = bitmap_modified,
	.render = bitmap_render,
};

struct gui_bitmap_table *monkey_bitmap_table = &bitmap_table;
