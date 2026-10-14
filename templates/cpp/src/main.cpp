#include <iostream>
#include <string_view>

int main([[maybe_unused]] int argc, [[maybe_unused]] char* argv[]) {
    constexpr std::string_view projectName = "{{PROJECT_NAME}}";

    std::cout << "========================================" << std::endl;
    std::cout << "  Project:  " << projectName << std::endl;
    std::cout << "  Language: C++ (C++20)" << std::endl;
    std::cout << "  Status:   Ready to build and run!" << std::endl;
    std::cout << "========================================" << std::endl;

    return 0;
}
