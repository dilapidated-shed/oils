/* ImportC declarations use the build target's libc ABI, including regex_t.
 * Parsing, lowering, evaluation and match state remain in D. */
#define _GNU_SOURCE 1
#include <fnmatch.h>
#include <glob.h>
#include <regex.h>
