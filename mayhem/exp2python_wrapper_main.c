/*
 * mayhem/exp2python_wrapper_main.c -- writable-scratch fix for the exp2python fuzz target,
 * WITHOUT a Mayhemfile `cwd:` key.
 *
 * Why this exists: exp2python has no output-directory flag. It parses the single .exp schema
 * given on the command line and writes <schema-name>.{py,h} with a bare, relative FILEcreate()
 * call (src/exp2python/src/classes_wrapper_python.cc SCHEMAprint(), driven from
 * src/exp2python/src/multpass_python.c print_schemas_separate()) -- i.e. into whatever the
 * process's current working directory happens to be. Mayhem mounts the commit image read-only
 * during coverage collection, so the process needs its cwd already pointing somewhere writable
 * before that happens.
 *
 * The naive fix -- a per-cmd `cwd: /tmp` key in the Mayhemfile -- is WRONG for a raw
 * (non-libFuzzer), process-per-input executable target: it restart-loops mayhem-fuzz ITSELF (the
 * supervisor, not the target), which dies with rc 254, so tests_run/edges_covered stay 0 for the
 * whole run while docker build, fuzz-smoke and the mayhem.yml Action all report success (issue
 * #661). Proven in this fleet: savantenvs/abc (target `demo`), savantenvs/microscheme and
 * savantenvs/svf (target `saber`) all hit this and were fixed by moving the chdir INSIDE the
 * binary instead.
 *
 * Fix: mayhem/build.sh compiles src/express/fedex.c (which provides the shared main() for every
 * exp2* / check-express tool via EXPRESSinit_init hooks -- see fedex.c's own comment) with
 * `-Dmain=exp2python_original_main`, a plain, fully-additive preprocessor rename -- no upstream
 * file is edited -- and links in this file, which supplies the real main(): resolve the input
 * path to an ABSOLUTE path, then chdir("/tmp/exp2python-out") before handing off to the renamed
 * original. This object is compiled WITHOUT that -D, so its own main() keeps its name.
 *
 * ORDER MATTERS: resolve argv[1] to an ABSOLUTE path *before* chdir(), not after -- Mayhem does
 * not guarantee the staged `@@` input is already an absolute path, and once the cwd has moved a
 * relative input path would no longer resolve (mirrors mayhem/abc_wrapper_main.c's precedent).
 */
#include <errno.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

extern int exp2python_original_main(int argc, char **argv);

int main(int argc, char **argv) {
    static char resolved[PATH_MAX];

    /* argv[1] is exp2python's one positional arg (the .exp schema). Resolve it to absolute
     * BEFORE the chdir below; leave it alone if it doesn't resolve (e.g. genuinely missing --
     * exp2python's own error path handles that the same as always). */
    if (argc > 1 && argv[1][0] != '-' && realpath(argv[1], resolved) != NULL) {
        argv[1] = resolved;
    }

    if (mkdir("/tmp/exp2python-out", 0777) != 0 && errno != EEXIST) {
        perror("mayhem: mkdir(/tmp/exp2python-out)");
        return 1;
    }
    if (chdir("/tmp/exp2python-out") != 0) {
        perror("mayhem: chdir(/tmp/exp2python-out)");
        return 1;
    }

    return exp2python_original_main(argc, argv);
}
