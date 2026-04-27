// Pull in `getxattr`, `setxattr`, `listxattr`, `removexattr` plus
// the matching constants. Linux's signatures take 4 args (no
// `position` / `options` like Darwin's 6-arg variants).
#include <sys/xattr.h>
