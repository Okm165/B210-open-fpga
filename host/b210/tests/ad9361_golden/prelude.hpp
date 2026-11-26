// SPDX-License-Identifier: GPL-3.0-or-later
//
// Force-included (g++ -include) before UHD's ad9361_device.cpp in the golden
// harness: every std::this_thread::sleep_for in the driver becomes
// golden_sleep, which writes the wait to the trace instead of sleeping. The
// standard and boost headers the driver uses are included first, so the
// macro below renames only the driver's calls.
#ifndef GOLDEN_PRELUDE_HPP
#define GOLDEN_PRELUDE_HPP

#include <boost/format.hpp>
#include <boost/math/special_functions.hpp>
#include <boost/scoped_array.hpp>
#include <boost/shared_ptr.hpp>
#include <chrono>
#include <cmath>
#include <functional>
#include <map>
#include <mutex>
#include <thread>
#include <tuple>
#include <vector>

namespace golden {
void sleep_us(long long us);
}

namespace std { namespace this_thread {
template <class Rep, class Period>
void golden_sleep(const std::chrono::duration<Rep, Period>& d)
{
    golden::sleep_us(std::chrono::duration_cast<std::chrono::microseconds>(d).count());
}
}} // namespace std::this_thread

#define sleep_for golden_sleep

#endif
