/* holbuild's entry point, in place of the main in Poly/ML's libpolymain.  It
   starts holbuild's own runtime with a heap floor, --minheap=128, by putting
   that option first on the command line the runtime parses.

   Workaround for a released Poly/ML, to drop with the analyser's floor
   (analyser_min_heap_mb in sml/dependencies.sml; #280 tracks the removal) once
   the toolchain's Poly/ML has the heap-sizing and segmentation rework of
   Poly/ML master: from Poly's 8 MB initial heap, an allocation of a few MB can
   fail - the collector reports "Completed with insufficient space", the
   runtime prints "Run out of store - interrupting threads", waits 5 s and
   holbuild stops with "interrupted".  Poly/ML 5.9.2 reads its runtime options
   only from the command line, so the floor goes in here.

   A user who sizes the heap (-H, --minheap or --maxheap) gets no floor: Poly
   refuses an initial or maximum size below the minimum, so the floor would
   turn "-H 64" into a usage error.  The match is Poly's own: an argument that
   starts with the option's name.  The kernel's copy of the command line
   (/proc/self/cmdline, which holbuild reads for the runtime options a user
   gave) doesn't hold the floor. */

#include <stdlib.h>
#include <string.h>

struct _exportDescription;
extern struct _exportDescription poly_exports;
extern int polymain(int argc, char **argv, struct _exportDescription *exports);

static int sizes_heap(const char *arg)
{
    return strncmp(arg, "-H", 2) == 0 || strncmp(arg, "--minheap", 9) == 0
        || strncmp(arg, "--maxheap", 9) == 0;
}

int main(int argc, char **argv)
{
    for (int i = 1; i < argc; i++)
        if (sizes_heap(argv[i]))
            return polymain(argc, argv, &poly_exports);
    char **args = malloc((argc + 2) * sizeof *args);
    if (args == NULL)
        return polymain(argc, argv, &poly_exports);
    args[0] = argv[0];
    args[1] = "--minheap=128";
    /* argv[argc] is the terminating NULL. */
    memcpy(args + 2, argv + 1, argc * sizeof *args);
    return polymain(argc + 1, args, &poly_exports);
}
