#define _POSIX_C_SOURCE 200809L

#include <cairo/cairo.h>
#include <errno.h>
#include <fcntl.h>
#include <gdk-pixbuf/gdk-pixbuf.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/wait.h>
#include <sys/types.h>
#include <unistd.h>
#include <wayland-client.h>
#include <wayland-client-protocol.h>

#include "wlr-layer-shell-unstable-v1-client-protocol.h"

enum wallpaper_mode {
  WALLPAPER_FIT,
  WALLPAPER_FILL,
  WALLPAPER_STRETCH,
  WALLPAPER_CENTER,
  WALLPAPER_TILE,
};

struct render_buffer {
  struct wl_list link;
  struct wl_buffer *buffer;
  void *data;
  size_t size;
  int fd;
  int width;
  int height;
};

struct output_state {
  struct wl_list link;
  struct wl_output *wl_output;
  struct wl_surface *surface;
  struct zwlr_layer_surface_v1 *layer_surface;
  char name[128];
  int configured_width;
  int configured_height;
  int output_width;
  int output_height;
  int scale;
  bool has_mode;
  bool configured;
  bool closed;
};

struct renderer_context {
  struct wl_display *display;
  struct wl_registry *registry;
  struct wl_compositor *compositor;
  struct wl_shm *shm;
  struct zwlr_layer_shell_v1 *layer_shell;
  struct wl_list outputs;
  struct wl_list buffers;
  int output_count;
};

static struct renderer_context g_ctx;

static void write_reply(const char *id, const char *status, const char *command, const char *message) {
  printf("{\"id\":\"%s\",\"status\":\"%s\",\"command\":\"%s\",\"message\":\"%s\"}\n", id, status, command, message);
  fflush(stdout);
}

static const char *extract_value(const char *json, const char *key, char *buffer, size_t size) {
  char pattern[128];
  snprintf(pattern, sizeof(pattern), "\"%s\"", key);

  const char *position = strstr(json, pattern);
  if (position == NULL) {
    return NULL;
  }

  position = strchr(position + strlen(pattern), ':');
  if (position == NULL) {
    return NULL;
  }

  while (*position != '\0' && (*position == ':' || *position == ' ' || *position == '\t' || *position == '\n' || *position == '\r')) {
    position++;
  }

  if (*position != '"') {
    return NULL;
  }

  position++;
  size_t index = 0;

  while (*position != '\0' && *position != '"' && index + 1 < size) {
    if (*position == '\\' && position[1] != '\0') {
      position++;
    }

    buffer[index++] = *position++;
  }

  buffer[index] = '\0';
  return buffer;
}

static enum wallpaper_mode parse_wallpaper_mode(const char *value) {
  if (value == NULL || value[0] == '\0') {
    return WALLPAPER_FIT;
  }

  if (strcmp(value, "fill") == 0) {
    return WALLPAPER_FILL;
  }

  if (strcmp(value, "stretch") == 0) {
    return WALLPAPER_STRETCH;
  }

  if (strcmp(value, "center") == 0) {
    return WALLPAPER_CENTER;
  }

  if (strcmp(value, "tile") == 0) {
    return WALLPAPER_TILE;
  }

  return WALLPAPER_FIT;
}

static const char *mode_to_string(enum wallpaper_mode mode) {
  switch (mode) {
    case WALLPAPER_FILL:
      return "fill";
    case WALLPAPER_STRETCH:
      return "stretch";
    case WALLPAPER_CENTER:
      return "center";
    case WALLPAPER_TILE:
      return "tile";
    case WALLPAPER_FIT:
    default:
      return "fit";
  }
}

static int run_program(char *const argv[]) {
  pid_t pid = fork();
  if (pid < 0) {
    return -1;
  }

  if (pid == 0) {
    execvp(argv[0], argv);
    _exit(127);
  }

  int status = 0;
  if (waitpid(pid, &status, 0) < 0) {
    return -1;
  }

  if (WIFEXITED(status)) {
    return WEXITSTATUS(status);
  }

  return -1;
}

static void build_file_uri(const char *path, char *output, size_t size) {
  size_t index = 0;
  const char *prefix = "file://";

  for (size_t i = 0; prefix[i] != '\0' && index + 1 < size; ++i) {
    output[index++] = prefix[i];
  }

  for (size_t i = 0; path[i] != '\0' && index + 4 < size; ++i) {
    unsigned char ch = (unsigned char)path[i];
    if (ch == ' ') {
      output[index++] = '%';
      output[index++] = '2';
      output[index++] = '0';
    } else if (ch == '%') {
      output[index++] = '%';
      output[index++] = '2';
      output[index++] = '5';
    } else if (ch == '#') {
      output[index++] = '%';
      output[index++] = '2';
      output[index++] = '3';
    } else if (ch == '?') {
      output[index++] = '%';
      output[index++] = '3';
      output[index++] = 'F';
    } else {
      output[index++] = (char)ch;
    }
  }

  output[index] = '\0';
}

static int apply_plasma_wallpaper(const char *path, char *error, size_t error_size) {
  char uri[2048];
  char escaped_uri[4096];
  char script[6144];

  build_file_uri(path, uri, sizeof(uri));

  size_t index = 0;
  for (size_t i = 0; uri[i] != '\0' && index + 2 < sizeof(escaped_uri); ++i) {
    char ch = uri[i];
    if (ch == '\\' || ch == '"') {
      escaped_uri[index++] = '\\';
      escaped_uri[index++] = ch;
    } else if (ch == '\n' || ch == '\r' || ch == '\t') {
      escaped_uri[index++] = ' ';
    } else {
      escaped_uri[index++] = ch;
    }
  }
  escaped_uri[index] = '\0';

  snprintf(
    script,
    sizeof(script),
    "var desktops = desktops();"
    "for (var i = 0; i < desktops.length; ++i) {"
    "  var d = desktops[i];"
    "  d.wallpaperPlugin = 'org.kde.image';"
    "  d.currentConfigGroup = ['Wallpaper', 'org.kde.image', 'General'];"
    "  d.writeConfig('Image', '%s');"
    "  d.reloadConfig();"
    "}",
    escaped_uri
  );

  char *const argv[] = {
    "gdbus",
    "call",
    "--session",
    "--dest",
    "org.kde.plasmashell",
    "--object-path",
    "/PlasmaShell",
    "--method",
    "org.kde.PlasmaShell.evaluateScript",
    script,
    NULL
  };

  int rc = run_program(argv);
  if (rc != 0) {
    snprintf(error, error_size, "KDE Plasma wallpaper update failed (exit %d)", rc);
    return -1;
  }

  snprintf(error, error_size, "wallpaper applied via KDE Plasma DBus fallback");
  return 0;
}

static int should_use_plasma_backend(void) {
  const char *desktop = getenv("XDG_CURRENT_DESKTOP");
  const char *session = getenv("XDG_SESSION_TYPE");

  if (desktop != NULL && (strstr(desktop, "KDE") != NULL || strstr(desktop, "Plasma") != NULL)) {
    return 1;
  }

  if (session != NULL && strcmp(session, "wayland") == 0 && desktop != NULL && strstr(desktop, "KDE") != NULL) {
    return 1;
  }

  return 0;
}

static int create_shm_file(size_t size) {
  char template[] = "/tmp/fw-shm-XXXXXX";
  int fd = mkstemp(template);
  if (fd < 0) {
    return -1;
  }

  unlink(template);

  if (ftruncate(fd, (off_t)size) < 0) {
    close(fd);
    return -1;
  }

  return fd;
}

static cairo_surface_t *pixbuf_to_cairo_surface(GdkPixbuf *pixbuf) {
  int width = gdk_pixbuf_get_width(pixbuf);
  int height = gdk_pixbuf_get_height(pixbuf);
  int rowstride = gdk_pixbuf_get_rowstride(pixbuf);
  int channels = gdk_pixbuf_get_n_channels(pixbuf);
  gboolean has_alpha = gdk_pixbuf_get_has_alpha(pixbuf);
  guchar *pixels = gdk_pixbuf_get_pixels(pixbuf);
  size_t stride = (size_t)width * 4;
  uint32_t *data = calloc((size_t)height, stride);

  if (data == NULL) {
    return NULL;
  }

  for (int y = 0; y < height; ++y) {
    uint32_t *row = (uint32_t *)((uint8_t *)data + (size_t)y * stride);
    guchar *src = pixels + (size_t)y * rowstride;

    for (int x = 0; x < width; ++x) {
      guchar *p = src + (size_t)x * channels;
      uint8_t red = p[0];
      uint8_t green = p[1];
      uint8_t blue = p[2];
      uint8_t alpha = has_alpha ? p[3] : 255;

      uint8_t premultiplied_red = (uint8_t)((red * alpha + 127) / 255);
      uint8_t premultiplied_green = (uint8_t)((green * alpha + 127) / 255);
      uint8_t premultiplied_blue = (uint8_t)((blue * alpha + 127) / 255);

      row[x] = ((uint32_t)alpha << 24) |
               ((uint32_t)premultiplied_red << 16) |
               ((uint32_t)premultiplied_green << 8) |
               (uint32_t)premultiplied_blue;
    }
  }

  cairo_surface_t *surface = cairo_image_surface_create_for_data((unsigned char *)data, CAIRO_FORMAT_ARGB32, width, height, (int)stride);
  if (cairo_surface_status(surface) != CAIRO_STATUS_SUCCESS) {
    free(data);
    cairo_surface_destroy(surface);
    return NULL;
  }

  return surface;
}

static struct render_buffer *create_render_buffer(struct renderer_context *ctx, int width, int height) {
  size_t stride = (size_t)width * 4;
  size_t size = stride * (size_t)height;
  int fd = create_shm_file(size);
  if (fd < 0) {
    return NULL;
  }

  void *data = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
  if (data == MAP_FAILED) {
    close(fd);
    return NULL;
  }

  struct wl_shm_pool *pool = wl_shm_create_pool(ctx->shm, fd, (int)size);
  if (pool == NULL) {
    munmap(data, size);
    close(fd);
    return NULL;
  }

  struct wl_buffer *buffer = wl_shm_pool_create_buffer(pool, 0, width, height, (int)stride, WL_SHM_FORMAT_ARGB8888);
  wl_shm_pool_destroy(pool);

  if (buffer == NULL) {
    munmap(data, size);
    close(fd);
    return NULL;
  }

  struct render_buffer *result = calloc(1, sizeof(*result));
  if (result == NULL) {
    wl_buffer_destroy(buffer);
    munmap(data, size);
    close(fd);
    return NULL;
  }

  result->buffer = buffer;
  result->data = data;
  result->size = size;
  result->fd = fd;
  result->width = width;
  result->height = height;
  wl_list_insert(&ctx->buffers, &result->link);

  return result;
}

static void destroy_render_buffers(struct renderer_context *ctx) {
  struct render_buffer *buffer;
  struct render_buffer *tmp;

  wl_list_for_each_safe(buffer, tmp, &ctx->buffers, link) {
    wl_list_remove(&buffer->link);
    if (buffer->buffer != NULL) {
      wl_buffer_destroy(buffer->buffer);
    }
    if (buffer->data != NULL && buffer->size > 0) {
      munmap(buffer->data, buffer->size);
    }
    if (buffer->fd >= 0) {
      close(buffer->fd);
    }
    free(buffer);
  }
}

static int draw_image_to_buffer(struct render_buffer *buffer, GdkPixbuf *pixbuf, enum wallpaper_mode mode) {
  cairo_surface_t *source_surface = pixbuf_to_cairo_surface(pixbuf);
  if (source_surface == NULL) {
    return -1;
  }

  cairo_surface_t *target_surface = cairo_image_surface_create_for_data((unsigned char *)buffer->data, CAIRO_FORMAT_ARGB32, buffer->width, buffer->height, buffer->width * 4);
  if (cairo_surface_status(target_surface) != CAIRO_STATUS_SUCCESS) {
    cairo_surface_destroy(source_surface);
    return -1;
  }

  cairo_t *cr = cairo_create(target_surface);
  cairo_set_operator(cr, CAIRO_OPERATOR_SOURCE);
  cairo_set_source_rgb(cr, 0.0, 0.0, 0.0);
  cairo_paint(cr);

  int src_width = gdk_pixbuf_get_width(pixbuf);
  int src_height = gdk_pixbuf_get_height(pixbuf);
  double dst_width = (double)buffer->width;
  double dst_height = (double)buffer->height;

  if (mode == WALLPAPER_TILE) {
    cairo_pattern_t *pattern = cairo_pattern_create_for_surface(source_surface);
    cairo_pattern_set_extend(pattern, CAIRO_EXTEND_REPEAT);
    cairo_set_source(cr, pattern);
    cairo_paint(cr);
    cairo_pattern_destroy(pattern);
  } else {
    double scale_x = dst_width / (double)src_width;
    double scale_y = dst_height / (double)src_height;
    double scale = 1.0;
    double translate_x = 0.0;
    double translate_y = 0.0;

    switch (mode) {
      case WALLPAPER_STRETCH:
        cairo_scale(cr, scale_x, scale_y);
        break;

      case WALLPAPER_FILL:
        scale = scale_x > scale_y ? scale_x : scale_y;
        translate_x = (dst_width - (double)src_width * scale) / 2.0;
        translate_y = (dst_height - (double)src_height * scale) / 2.0;
        cairo_translate(cr, translate_x, translate_y);
        cairo_scale(cr, scale, scale);
        break;

      case WALLPAPER_CENTER:
        translate_x = (dst_width - (double)src_width) / 2.0;
        translate_y = (dst_height - (double)src_height) / 2.0;
        cairo_translate(cr, translate_x, translate_y);
        break;

      case WALLPAPER_FIT:
      default:
        scale = scale_x < scale_y ? scale_x : scale_y;
        translate_x = (dst_width - (double)src_width * scale) / 2.0;
        translate_y = (dst_height - (double)src_height * scale) / 2.0;
        cairo_translate(cr, translate_x, translate_y);
        cairo_scale(cr, scale, scale);
        break;
    }

    cairo_set_source_surface(cr, source_surface, 0.0, 0.0);
    cairo_paint(cr);
  }

  cairo_destroy(cr);
  cairo_surface_flush(target_surface);
  cairo_surface_destroy(target_surface);
  cairo_surface_destroy(source_surface);
  return 0;
}

static void output_handle_geometry(void *data, struct wl_output *wl_output, int32_t x, int32_t y, int32_t physical_width, int32_t physical_height, int32_t subpixel, const char *make, const char *model, int32_t transform) {
  struct output_state *output = data;
  (void)wl_output;
  (void)x;
  (void)y;
  (void)physical_width;
  (void)physical_height;
  (void)subpixel;
  (void)make;
  (void)model;
  (void)transform;
  output->has_mode = false;
}

static void output_handle_mode(void *data, struct wl_output *wl_output, uint32_t flags, int32_t width, int32_t height, int32_t refresh) {
  struct output_state *output = data;
  (void)wl_output;
  (void)refresh;

  if (flags & WL_OUTPUT_MODE_CURRENT) {
    output->output_width = width;
    output->output_height = height;
    output->has_mode = true;
  }
}

static void output_handle_done(void *data, struct wl_output *wl_output) {
  struct output_state *output = data;
  (void)wl_output;
  output->configured = output->configured;
}

static void output_handle_scale(void *data, struct wl_output *wl_output, int32_t factor) {
  struct output_state *output = data;
  (void)wl_output;
  if (factor > 0) {
    output->scale = factor;
  }
}

static void output_handle_name(void *data, struct wl_output *wl_output, const char *name) {
  struct output_state *output = data;
  (void)wl_output;
  snprintf(output->name, sizeof(output->name), "%s", name);
}

static void output_handle_description(void *data, struct wl_output *wl_output, const char *description) {
  (void)data;
  (void)wl_output;
  (void)description;
}

static const struct wl_output_listener output_listener = {
  .geometry = output_handle_geometry,
  .mode = output_handle_mode,
  .done = output_handle_done,
  .scale = output_handle_scale,
  .name = output_handle_name,
  .description = output_handle_description,
};

static void layer_surface_configure(void *data, struct zwlr_layer_surface_v1 *layer_surface, uint32_t serial, uint32_t width, uint32_t height) {
  struct output_state *output = data;
  output->configured_width = (int)width;
  output->configured_height = (int)height;
  output->configured = true;
  zwlr_layer_surface_v1_ack_configure(layer_surface, serial);
}

static void layer_surface_closed(void *data, struct zwlr_layer_surface_v1 *layer_surface) {
  struct output_state *output = data;
  output->closed = true;
  (void)layer_surface;
}

static const struct zwlr_layer_surface_v1_listener layer_surface_listener = {
  .configure = layer_surface_configure,
  .closed = layer_surface_closed,
};

static void output_destroy(struct output_state *output) {
  if (output == NULL) {
    return;
  }

  if (output->layer_surface != NULL) {
    zwlr_layer_surface_v1_destroy(output->layer_surface);
  }

  if (output->surface != NULL) {
    wl_surface_destroy(output->surface);
  }

  if (output->wl_output != NULL) {
    wl_output_destroy(output->wl_output);
  }

  free(output);
}

static int create_output_surface(struct renderer_context *ctx, struct output_state *output) {
  output->surface = wl_compositor_create_surface(ctx->compositor);
  if (output->surface == NULL) {
    return -1;
  }

  output->layer_surface = zwlr_layer_shell_v1_get_layer_surface(ctx->layer_shell, output->surface, output->wl_output, ZWLR_LAYER_SHELL_V1_LAYER_BACKGROUND, "fw");
  if (output->layer_surface == NULL) {
    return -1;
  }

  zwlr_layer_surface_v1_add_listener(output->layer_surface, &layer_surface_listener, output);
  zwlr_layer_surface_v1_set_anchor(output->layer_surface, ZWLR_LAYER_SURFACE_V1_ANCHOR_TOP | ZWLR_LAYER_SURFACE_V1_ANCHOR_BOTTOM | ZWLR_LAYER_SURFACE_V1_ANCHOR_LEFT | ZWLR_LAYER_SURFACE_V1_ANCHOR_RIGHT);
  zwlr_layer_surface_v1_set_exclusive_zone(output->layer_surface, -1);
  zwlr_layer_surface_v1_set_keyboard_interactivity(output->layer_surface, ZWLR_LAYER_SURFACE_V1_KEYBOARD_INTERACTIVITY_NONE);
  zwlr_layer_surface_v1_set_margin(output->layer_surface, 0, 0, 0, 0);
  zwlr_layer_surface_v1_set_size(output->layer_surface, 0, 0);
  wl_surface_commit(output->surface);

  return 0;
}

static void registry_global(void *data, struct wl_registry *registry, uint32_t name, const char *interface, uint32_t version) {
  struct renderer_context *ctx = data;

  if (strcmp(interface, wl_compositor_interface.name) == 0) {
    ctx->compositor = wl_registry_bind(registry, name, &wl_compositor_interface, version < 4 ? version : 4);
    return;
  }

  if (strcmp(interface, wl_shm_interface.name) == 0) {
    ctx->shm = wl_registry_bind(registry, name, &wl_shm_interface, 1);
    return;
  }

  if (strcmp(interface, zwlr_layer_shell_v1_interface.name) == 0) {
    ctx->layer_shell = wl_registry_bind(registry, name, &zwlr_layer_shell_v1_interface, version < 4 ? version : 4);
    return;
  }

  if (strcmp(interface, wl_output_interface.name) == 0) {
    struct output_state *output = calloc(1, sizeof(*output));
    if (output == NULL) {
      return;
    }

    output->wl_output = wl_registry_bind(registry, name, &wl_output_interface, version < 4 ? version : 4);
    output->scale = 1;
    wl_list_insert(&ctx->outputs, &output->link);
    wl_output_add_listener(output->wl_output, &output_listener, output);
    ctx->output_count += 1;
  }
}

static const struct wl_registry_listener registry_listener = {
  .global = registry_global,
};

static void init_context(struct renderer_context *ctx) {
  memset(ctx, 0, sizeof(*ctx));
  wl_list_init(&ctx->outputs);
  wl_list_init(&ctx->buffers);
}

static int ensure_wayland_context(struct renderer_context *ctx, char *error, size_t error_size) {
  if (ctx->display != NULL) {
    return 0;
  }

  ctx->display = wl_display_connect(NULL);
  if (ctx->display == NULL) {
    snprintf(error, error_size, "cannot connect to Wayland display");
    return -1;
  }

  ctx->registry = wl_display_get_registry(ctx->display);
  if (ctx->registry == NULL) {
    snprintf(error, error_size, "cannot get Wayland registry");
    return -1;
  }

  wl_registry_add_listener(ctx->registry, &registry_listener, ctx);
  if (wl_display_roundtrip(ctx->display) < 0) {
    snprintf(error, error_size, "Wayland registry roundtrip failed");
    return -1;
  }

  if (ctx->compositor == NULL || ctx->shm == NULL || ctx->layer_shell == NULL) {
    snprintf(error, error_size, "missing compositor, shm, or wlr-layer-shell support");
    return -1;
  }

  if (ctx->output_count <= 0) {
    snprintf(error, error_size, "no Wayland outputs were discovered");
    return -1;
  }

  return 0;
}

static int prepare_layer_surfaces(struct renderer_context *ctx, char *error, size_t error_size) {
  struct output_state *output;
  wl_list_for_each(output, &ctx->outputs, link) {
    if (output->layer_surface == NULL) {
      if (create_output_surface(ctx, output) != 0) {
        snprintf(error, error_size, "failed to create layer-shell surface");
        return -1;
      }
    }
  }

  if (wl_display_roundtrip(ctx->display) < 0) {
    snprintf(error, error_size, "layer-shell configure roundtrip failed");
    return -1;
  }

  wl_list_for_each(output, &ctx->outputs, link) {
    if (output->closed) {
      snprintf(error, error_size, "an output closed before configuration completed");
      return -1;
    }

    if (!output->configured) {
      snprintf(error, error_size, "timed out waiting for layer-shell configure");
      return -1;
    }
  }

  return 0;
}

static int render_wallpaper_to_outputs(struct renderer_context *ctx, GdkPixbuf *pixbuf, enum wallpaper_mode mode, char *error, size_t error_size) {
  struct output_state *output;
  wl_list_for_each(output, &ctx->outputs, link) {
    int logical_width = output->configured_width > 0 ? output->configured_width : output->output_width;
    int logical_height = output->configured_height > 0 ? output->configured_height : output->output_height;

    if (logical_width <= 0 || logical_height <= 0) {
      logical_width = gdk_pixbuf_get_width(pixbuf);
      logical_height = gdk_pixbuf_get_height(pixbuf);
    }

    int scale = output->scale > 0 ? output->scale : 1;
    int buffer_width = logical_width * scale;
    int buffer_height = logical_height * scale;

    if (buffer_width <= 0 || buffer_height <= 0) {
      snprintf(error, error_size, "invalid output size");
      return -1;
    }

    struct render_buffer *render_buffer = create_render_buffer(ctx, buffer_width, buffer_height);
    if (render_buffer == NULL) {
      snprintf(error, error_size, "failed to allocate Wayland SHM buffer");
      return -1;
    }

    if (draw_image_to_buffer(render_buffer, pixbuf, mode) != 0) {
      snprintf(error, error_size, "failed to draw wallpaper image");
      return -1;
    }

    wl_surface_set_buffer_scale(output->surface, scale);
    wl_surface_attach(output->surface, render_buffer->buffer, 0, 0);
    wl_surface_damage_buffer(output->surface, 0, 0, buffer_width, buffer_height);
    wl_surface_commit(output->surface);
  }

  if (wl_display_flush(ctx->display) < 0) {
    snprintf(error, error_size, "Wayland flush failed");
    return -1;
  }

  return 0;
}

static int apply_layer_shell_wallpaper(const char *path, const char *scaling, char *error, size_t error_size) {
  if (ensure_wayland_context(&g_ctx, error, error_size) != 0) {
    return -1;
  }

  GError *g_error = NULL;
  GdkPixbuf *pixbuf = gdk_pixbuf_new_from_file(path, &g_error);
  if (pixbuf == NULL) {
    snprintf(error, error_size, "failed to load image: %s", g_error != NULL ? g_error->message : "unknown error");
    if (g_error != NULL) {
      g_error_free(g_error);
    }
    return -1;
  }

  if (prepare_layer_surfaces(&g_ctx, error, error_size) != 0) {
    g_object_unref(pixbuf);
    return -1;
  }

  if (render_wallpaper_to_outputs(&g_ctx, pixbuf, parse_wallpaper_mode(scaling), error, error_size) != 0) {
    g_object_unref(pixbuf);
    return -1;
  }

  g_object_unref(pixbuf);
  snprintf(error, error_size, "wallpaper applied via native wlr-layer-shell (%s)", mode_to_string(parse_wallpaper_mode(scaling)));
  return 0;
}

static int apply_wallpaper(const char *path, const char *scaling, char *error, size_t error_size) {
  if (should_use_plasma_backend()) {
    return apply_plasma_wallpaper(path, error, error_size);
  }

  return apply_layer_shell_wallpaper(path, scaling, error, error_size);
}

static void destroy_context(struct renderer_context *ctx) {
  destroy_render_buffers(ctx);

  struct output_state *output;
  struct output_state *tmp;
  wl_list_for_each_safe(output, tmp, &ctx->outputs, link) {
    wl_list_remove(&output->link);
    output_destroy(output);
  }

  if (ctx->layer_shell != NULL) {
    zwlr_layer_shell_v1_destroy(ctx->layer_shell);
    ctx->layer_shell = NULL;
  }

  if (ctx->shm != NULL) {
    wl_shm_destroy(ctx->shm);
    ctx->shm = NULL;
  }

  if (ctx->compositor != NULL) {
    wl_compositor_destroy(ctx->compositor);
    ctx->compositor = NULL;
  }

  if (ctx->registry != NULL) {
    wl_registry_destroy(ctx->registry);
    ctx->registry = NULL;
  }

  if (ctx->display != NULL) {
    wl_display_disconnect(ctx->display);
    ctx->display = NULL;
  }
}

int main(void) {
  init_context(&g_ctx);

  char line[4096];
  char id[256];
  char command[256];

  fprintf(stderr, "fw_renderer: ready\n");
  fflush(stderr);

  while (fgets(line, sizeof(line), stdin) != NULL) {
    id[0] = '\0';
    command[0] = '\0';

    if (extract_value(line, "id", id, sizeof(id)) == NULL) {
      strcpy(id, "0");
    }

    if (extract_value(line, "command", command, sizeof(command)) == NULL) {
      strcpy(command, "unknown");
    }

    fprintf(stderr, "fw_renderer: command=%s id=%s\n", command, id);
    fflush(stderr);

    if (strcmp(command, "shutdown") == 0) {
      destroy_context(&g_ctx);
      write_reply(id, "ok", command, "renderer stopping");
      break;
    }

    if (strcmp(command, "ping") == 0) {
      write_reply(id, "ok", command, "pong from native Wayland renderer");
      continue;
    }

    if (strcmp(command, "status") == 0) {
      write_reply(id, "ok", command, g_ctx.display != NULL ? "native renderer ready" : "renderer not connected");
      continue;
    }

    if (strcmp(command, "apply") == 0) {
      char path[2048];
      char scaling[128];
      char reply[512];

      if (extract_value(line, "path", path, sizeof(path)) == NULL || path[0] == '\0') {
        write_reply(id, "error", command, "missing wallpaper path");
        continue;
      }

      if (extract_value(line, "scaling", scaling, sizeof(scaling)) == NULL) {
        scaling[0] = '\0';
      }

      if (apply_wallpaper(path, scaling, reply, sizeof(reply)) != 0) {
        write_reply(id, "error", command, reply);
      } else {
        write_reply(id, "ok", command, reply);
      }

      continue;
    }

    write_reply(id, "error", command, "unsupported command");
  }

  destroy_context(&g_ctx);
  fprintf(stderr, "fw_renderer: exit\n");
  fflush(stderr);
  return 0;
}
