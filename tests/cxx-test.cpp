// C++ runtime test for the ILP32 user space: iostream, std::string/vector/map, exceptions (unwinding through
// libgcc_s), std::thread. Exit code: number of failed checks.
#include <iostream>
#include <map>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>

static int fails;
static void check(const char *what, bool ok)
{
	std::cout << "  " << (ok ? "ok    " : "FAIL  ") << what << "\n";
	if (!ok)
		fails++;
}

static int thrower(int depth)
{
	if (depth == 0)
		throw std::runtime_error("deep");
	return thrower(depth - 1) + 1;
}

int main()
{
	std::cout << "C++ test, sizeof(long)=" << sizeof(long) << " sizeof(void*)=" << sizeof(void *) << "\n";
	std::vector<std::string> v;
	for (int i = 0; i < 1000; i++)
		v.push_back(std::to_string(i));
	std::map<std::string, int> m;
	for (auto &s : v)
		m[s] = static_cast<int>(s.size());
	check("vector/string/map", v.size() == 1000 && m["999"] == 3);

	bool caught = false;
	try {
		thrower(50);
	} catch (const std::runtime_error &e) {
		caught = std::string(e.what()) == "deep";
	}
	check("exception through 50 frames", caught);

	int sum = 0;
	std::thread t([&] { for (int i = 1; i <= 100; i++) sum += i; });
	t.join();
	check("std::thread", sum == 5050);

	std::cout << "RESULT: " << (fails ? "FAIL" : "PASS") << " (" << fails << " failed)\n";
	return fails;
}
