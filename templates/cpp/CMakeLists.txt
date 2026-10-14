cmake_minimum_required(VERSION 3.20)

# Имя проекта с поддержкой плейсхолдера или имени каталога
project({{PROJECT_NAME}} LANGUAGES CXX C)

# Стандарт C++20
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

# Экспорт compile_commands.json для LSP (clangd, Neovim, VSCode)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

# Автоматический сбор всех исходных файлов из папки src/
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
