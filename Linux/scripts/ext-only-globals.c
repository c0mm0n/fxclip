/* Test-only compositor filter: exercise real ext-data-control with wlr hidden.
 * Keep Sway's existing security filter; never preload this into fxclip/clients.
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdbool.h>
#include <string.h>
#include <wayland-server-core.h>

static wl_display_global_filter_func_t original_filter;
static void *original_data;

static bool ext_only(const struct wl_client *client,
        const struct wl_global *global, void *data) {
    (void)data;
    if (strcmp(wl_global_get_interface(global)->name,
            "zwlr_data_control_manager_v1") == 0) {
        return false;
    }
    return !original_filter || original_filter(client, global, original_data);
}

void wl_display_set_global_filter(struct wl_display *display,
        wl_display_global_filter_func_t filter, void *data) {
    void (*set_filter)(struct wl_display *, wl_display_global_filter_func_t, void *) =
        dlsym(RTLD_NEXT, "wl_display_set_global_filter");
    original_filter = filter;
    original_data = data;
    set_filter(display, ext_only, NULL);
}
