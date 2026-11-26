// SPDX-License-Identifier: GPL-3.0-or-later
// Stands in for UHD's logging (which needs libuhd) in the golden harness:
// every log statement compiles to nothing. Used only by generate.sh.
#ifndef GOLDEN_STUB_UHD_LOG_HPP
#define GOLDEN_STUB_UHD_LOG_HPP

#include <sstream>

namespace golden {
struct null_log
{
    template <class T> null_log& operator<<(const T&) { return *this; }
};
} // namespace golden

#define UHD_LOGGER_TRACE(component) golden::null_log()
#define UHD_LOGGER_DEBUG(component) golden::null_log()
#define UHD_LOGGER_INFO(component) golden::null_log()
#define UHD_LOGGER_WARNING(component) golden::null_log()
#define UHD_LOGGER_ERROR(component) golden::null_log()
#define UHD_LOG_TRACE(component, message) ((void)0)
#define UHD_LOG_DEBUG(component, message) ((void)0)

#endif
