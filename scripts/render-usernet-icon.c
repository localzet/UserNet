#include <gdk-pixbuf/gdk-pixbuf.h>
#include <stdlib.h>

int main(int argc, char **argv) {
    if (argc != 4) return 2;
    int size = atoi(argv[2]);
    if (size <= 0 || size > 4096) return 2;
    GError *error = NULL;
    GdkPixbuf *image = gdk_pixbuf_new_from_file_at_scale(argv[1], size, size, TRUE, &error);
    if (!image) {
        g_printerr("%s\n", error->message);
        g_error_free(error);
        return 1;
    }
    gboolean saved = gdk_pixbuf_save(image, argv[3], "png", &error, NULL);
    g_object_unref(image);
    if (!saved) {
        g_printerr("%s\n", error->message);
        g_error_free(error);
        return 1;
    }
    return 0;
}
