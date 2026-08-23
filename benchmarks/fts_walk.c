/* fts_walk.c - thin C wrapper around fts(3) so Zig does not need to
   reproduce Darwin's FTSENT layout. One call in, counters out. */
#include <fts.h>
#include <sys/stat.h>
#include <stdint.h>
#include <stdlib.h>

int fts_walk(const char *root, int sum_sizes,
             unsigned long long *entries_out, unsigned long long *bytes_out)
{
    char *argv[] = { (char *)root, NULL };
    FTS *ftsp = fts_open(argv, FTS_PHYSICAL | FTS_XDEV | FTS_NOCHDIR, NULL);
    if (!ftsp) return -1;

    unsigned long long entries = 0;
    unsigned long long bytes = 0;
    FTSENT *ent;
    while ((ent = fts_read(ftsp)) != NULL) {
        /* Skip fts's synthetic read-backs and the root entry itself so
           counts match readdir/bulk. */
        if (ent->fts_info == FTS_DP) continue;
        if (ent->fts_level == 0) continue; /* the root */
        entries++;
        if (sum_sizes && ent->fts_info == FTS_F && ent->fts_statp &&
            ent->fts_statp->st_size > 0) {
            bytes += (unsigned long long)ent->fts_statp->st_size;
        }
    }
    fts_close(ftsp);
    *entries_out = entries;
    *bytes_out = bytes;
    return 0;
}
