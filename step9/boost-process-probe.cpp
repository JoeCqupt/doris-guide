#include <boost/process.hpp>
#ifdef BOOST_POSIX_HAS_SIGTIMEDWAIT
#error macOS must not select sigtimedwait
#endif
int main() { return 0; }
