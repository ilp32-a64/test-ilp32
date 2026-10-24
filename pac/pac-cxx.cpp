// SPDX-License-Identifier: GPL-2.0
// C++ exceptions through frames with signed return addresses (-mbranch-protection=pac-ret):
// the unwinder has to authenticate or strip the return addresses. Exit status 0 if it works.
#include <cstdio>
#include <stdexcept>
#include <string>

static int destroyed;

struct Guard {
	~Guard() { destroyed++; }
};

static __attribute__((noinline)) int thrower(int n)
{
	Guard g;
	if (n == 0)
		throw std::runtime_error("bottom");
	return thrower(n - 1) + 1;
}

int main()
{
	int caught = 0;

	for (int i = 0; i < 100; i++) {
		try {
			thrower(20);
		} catch (const std::runtime_error &e) {
			if (std::string(e.what()) == "bottom")
				caught++;
		}
	}
	std::printf("pac-cxx: %d of 100 exceptions caught, %d destructors run (want 2100)\n", caught,
		    destroyed);
	return !(caught == 100 && destroyed == 2100);
}
