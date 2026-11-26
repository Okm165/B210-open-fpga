// SPDX-License-Identifier: GPL-3.0-or-later
// Stands in for UHD's exception classes (defined in libuhd) in the golden
// harness: the driver only throws uhd::runtime_error. Used only by generate.sh.
#ifndef GOLDEN_STUB_UHD_EXCEPTION_HPP
#define GOLDEN_STUB_UHD_EXCEPTION_HPP

#include <stdexcept>
#include <string>

namespace uhd {
struct runtime_error : std::runtime_error
{
    using std::runtime_error::runtime_error;
};
} // namespace uhd

#define UHD_THROW_INVALID_CODE_PATH() throw uhd::runtime_error("invalid code path")

#endif
