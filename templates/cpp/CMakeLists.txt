cmake_minimum_required(VERSION 3.20)

# Автоматическое имя проекта по названию текущей папки, если не задано явно
get_filename_component(DEFAULT_PROJECT_NAME "${CMAKE_CURRENT_SOURCE_DIR}" NAME)
project(${DEFAULT_PROJECT_NAME} CXX C)

# Стандарт C++
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

# Экспорт compile_commands.json для LSP (clangd, Neovim, VSCode)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

# Автоматический сбор всех исходных файлов из папки src/
# Флаг CONFIGURE_DEPENDS заставляет CMake автоматически перезапускаться при добавлении новых файлов
file(GLOB_RECURSE SOURCES CONFIGURE_DEPENDS
    "${CMAKE_CURRENT_SOURCE_DIR}/src/*.cpp"
    "${CMAKE_CURRENT_SOURCE_DIR}/src/*.cc"
    "${CMAKE_CURRENT_SOURCE_DIR}/src/*.cxx"
    "${CMAKE_CURRENT_SOURCE_DIR}/src/*.c"
)

# Проверка наличия исходников для сборки
if(NOT SOURCES)
    message(WARNING "В папке src/ не найдено исходных файлов (.cpp / .c). Создайте хотя бы один файл (например, src/main.cpp).")
endif()

# Создание исполняемого файла
add_executable(${PROJECT_NAME} ${SOURCES})

# Добавление src/ в список путей для #include <...>
target_include_directories(${PROJECT_NAME} PRIVATE
    "${CMAKE_CURRENT_SOURCE_DIR}/src"
)

# Базовые предупреждения компилятора
if(MSVC)
    target_compile_options(${PROJECT_NAME} PRIVATE /W4)
else()
    target_compile_options(${PROJECT_NAME} PRIVATE -Wall -Wextra -Wpedantic)
endif()
