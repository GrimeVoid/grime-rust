use std::fs;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use grime::orchestrator::Orchestrator;
use grime::payload::PipelinePayload;
use grime::pipeline::parse_pipeline_args;

// RAII временная директория для тестов без внешних зависимостей
struct TestTempDir {
    path: PathBuf,
}

impl TestTempDir {
    fn new(prefix: &str) -> Self {
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let path = std::env::temp_dir().join(format!("{}_{}_{}", prefix, std::process::id(), nanos));
        fs::create_dir_all(&path).unwrap();
        Self { path }
    }

    fn path(&self) -> &Path {
        &self.path
    }
}

impl Drop for TestTempDir {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.path);
    }
}

// Вспомогательная функция для создания тестовых Lua-модулей
fn create_test_modules(temp_dir: &Path) {
    let mod_dir = temp_dir.join("modules");
    fs::create_dir_all(&mod_dir).unwrap();

    // Модуль 1: test_producer.lua
    fs::write(
        mod_dir.join("test_producer.lua"),
        r#"
        function main()
            grime.bus.set("pipeline.counter", 42)
            grime.bus.set("modules.producer.cache", "ok")
            grime.events.emit("producer.created", { count = 42 })
            
            grime.ctx.success("generated_data")
        end
    "#,
    )
    .unwrap();

    // Модуль 2: test_consumer.lua
    fs::write(
        mod_dir.join("test_consumer.lua"),
        r#"
        function main()
            local cnt = grime.bus.get("pipeline.counter")
            if cnt ~= 42 then
                grime.ctx.fail("Ожидалось pipeline.counter = 42, получено: " .. tostring(cnt))
                return
            end

            local payload = grime.ctx.get_payload()
            local text = payload and payload:to_string() or ""
            grime.bus.set("pipeline.received_text", text)
            grime.ctx.success("consumer_finished:" .. text)
        end
    "#,
    )
    .unwrap();

    // Модуль 3: test_cancellation.lua (бесконечный цикл с cleanup)
    fs::write(
        mod_dir.join("test_cancellation.lua"),
        r#"
        function cleanup()
            grime.bus.set("modules.test_cancellation.cleaned", true)
        end

        function main()
            grime.events.emit("cancellation.ready", { status = "waiting" })
            local i = 0
            while true do
                i = i + 1
            end
        end
    "#,
    )
    .unwrap();
}

#[tokio::test]
async fn test_stage1_shared_state_bus_and_raii() {
    let tmp = TestTempDir::new("grime_stage1");
    create_test_modules(tmp.path());

    let orch = Orchestrator::new(Some(tmp.path().join("modules")), None).unwrap();
    let parsed = parse_pipeline_args(&["test_producer".to_string(), ":".to_string(), "test_consumer".to_string()]);

    // До запуска
    assert!(!orch.state_bus().has("pipeline.counter"));

    // Запуск конвейера
    let res = orch.run_pipeline(&parsed).await;
    assert!(res.is_ok(), "Пайплайн завершился с ошибкой: {:?}", res);
    let output = res.unwrap().unwrap();
    assert_eq!(output, "consumer_finished:generated_data");

    // После завершения: RAII guard должен очистить все pipeline.* данные!
    assert!(
        !orch.state_bus().has("pipeline.counter"),
        "Сессионные данные pipeline.* должны быть очищены после завершения конвейера!"
    );
    assert!(
        !orch.state_bus().has("pipeline.received_text"),
        "Сессионные данные pipeline.* должны быть очищены!"
    );

    // Но персистентные данные modules.* должны сохраниться!
    assert_eq!(
        orch.state_bus().get("modules.producer.cache").unwrap(),
        serde_json::json!("ok")
    );

    // Системные данные system.* и env.* также на месте
    assert!(orch.state_bus().has("system.version"));
    assert!(orch.state_bus().has("system.pid"));
}

#[tokio::test]
async fn test_stage2_cancellation_and_cleanup() {
    let tmp = TestTempDir::new("grime_stage2");
    create_test_modules(tmp.path());

    let orch = Arc::new(Orchestrator::new(Some(tmp.path().join("modules")), None).unwrap());
    let parsed = parse_pipeline_args(&["test_cancellation".to_string()]);

    let orch_clone = orch.clone();
    let canceller = orch.canceller().clone();
    let mut rx = orch.event_bus().subscribe();

    // Отменяем ровно тогда, когда модуль запущен и начал работу
    std::thread::spawn(move || {
        while let Ok(ev) = rx.blocking_recv() {
            if ev.name == "cancellation.ready" {
                canceller.cancel("Тестовая отмена по SIGINT");
                break;
            }
        }
    });

    let start = std::time::Instant::now();
    let res = orch_clone.run_pipeline(&parsed).await;
    let elapsed = start.elapsed();

    // Пайплайн должен быть прерван и не зависнуть в бесконечном цикле
    assert!(res.is_err(), "Пайплайн должен завершиться с ошибкой прерывания");
    let err_msg = res.unwrap_err();
    assert!(
        err_msg.contains("отменен") || err_msg.contains("прерван") || err_msg.contains("[CANCELLATION]"),
        "Сообщение об ошибке должно содержать признак отмены: {}",
        err_msg
    );
    assert!(
        elapsed < Duration::from_secs(3),
        "Бесконечный цикл должен был прерваться хуком за доли секунды!"
    );

    // Проверяем, что была вызвана функция cleanup()
    assert_eq!(
        orch.state_bus().get("modules.test_cancellation.cleaned"),
        Some(serde_json::json!(true)),
        "Функция cleanup() задействованного модуля должна быть вызвана при отмене!"
    );
}

#[tokio::test]
async fn test_stage2_zero_copy_payload() {
    let original_payload = PipelinePayload::from_string("Grime Fast Zero-Copy Architecture".to_string());
    assert_eq!(original_payload.len(), 33);

    let slice1 = original_payload.slice(0, 5).unwrap();
    assert_eq!(slice1.as_str().unwrap(), "Grime");

    let slice2 = original_payload.slice(11, 9).unwrap();
    assert_eq!(slice2.as_str().unwrap(), "Zero-Copy");

    // Срез за границами
    assert!(original_payload.slice(30, 10).is_none());
}

#[tokio::test]
async fn test_stage4_event_bus_lifecycle() {
    let tmp = TestTempDir::new("grime_stage4");
    create_test_modules(tmp.path());

    let orch = Orchestrator::new(Some(tmp.path().join("modules")), None).unwrap();
    let mut rx = orch.event_bus().subscribe();

    let parsed = parse_pipeline_args(&["test_producer".to_string()]);
    let res = orch.run_pipeline(&parsed).await;
    assert!(res.is_ok());

    // Собираем события из EventBus
    let mut received_events = Vec::new();
    while let Ok(ev) = rx.try_recv() {
        received_events.push(ev.name);
    }

    assert!(
        received_events.contains(&"pipeline.start".to_string()),
        "Должно присутствовать событие pipeline.start"
    );
    assert!(
        received_events.contains(&"pipeline.step.start".to_string()),
        "Должно присутствовать событие pipeline.step.start"
    );
    assert!(
        received_events.contains(&"producer.created".to_string()),
        "Должно присутствовать кастомное событие из Lua producer.created"
    );
    assert!(
        received_events.contains(&"pipeline.step.finish".to_string()),
        "Должно присутствовать событие pipeline.step.finish"
    );
    assert!(
        received_events.contains(&"pipeline.finish".to_string()),
        "Должно присутствовать событие pipeline.finish"
    );
}

#[tokio::test]
async fn test_stage5_paths_registry_and_lua_context() {
    let tmp = TestTempDir::new("grime_stage5");
    let mod_dir = tmp.path().join("modules");
    fs::create_dir_all(&mod_dir).unwrap();

    // Копируем helper.lua в тестовую директорию
    let helper_src = Path::new("modules/helper.lua");
    if helper_src.exists() {
        fs::copy(helper_src, mod_dir.join("helper.lua")).unwrap();
    }

    // Создаем кастомный gproj.conf с произвольными путями
    let conf_path = tmp.path().join("gproj.conf");
    let conf_content = r#"
# Тестовая конфигурация
projects = /tmp/test_projects
custom_assets = /tmp/assets
custom_key = /tmp/special_dir
"#;
    fs::write(&conf_path, conf_content).unwrap();

    // Модуль test_paths.lua
    fs::write(
        mod_dir.join("test_paths.lua"),
        r#"
        local helper = require("helper")
        local ctx = helper.ctx

        function main()
            -- 1. Проверка прямого доступа через ctx.paths
            assert(ctx.paths ~= nil, "ctx.paths must exist")
            assert(ctx.paths.projects == "/tmp/test_projects", "projects path mismatch")
            assert(ctx.paths.custom_assets == "/tmp/assets", "custom_assets path mismatch")
            assert(ctx.paths.custom_key == "/tmp/special_dir", "custom_key path mismatch")

            -- 2. Проверка автоматических дефолтов
            assert(ctx.paths.apps ~= nil and #ctx.paths.apps > 0, "apps default missing")
            assert(ctx.paths.templates ~= nil and #ctx.paths.templates > 0, "templates default missing")
            assert(ctx.paths.config ~= nil and #ctx.paths.config > 0, "config default missing")

            -- 3. Проверка get_path
            assert(ctx.get_path("custom_assets") == "/tmp/assets")
            assert(ctx.get_path("nonexistent", "my_fallback") == "my_fallback")

            -- 4. Проверка grime.paths
            assert(grime.paths.custom_assets == "/tmp/assets")

            ctx.success("paths_ok")
        end
    "#,
    )
    .unwrap();

    let orch = Orchestrator::new(Some(mod_dir), Some(&conf_path)).unwrap();
    let parsed = parse_pipeline_args(&["test_paths".to_string()]);
    let res = orch.run_pipeline(&parsed).await;

    assert!(res.is_ok(), "Пайплайн с путями упал: {:?}", res);
    assert_eq!(res.unwrap().unwrap(), "paths_ok");
}

#[tokio::test]
async fn test_fuzzy_matching_entities_and_flags() {
    let temp = TestTempDir::new("grime_fuzzy_test");
    let mod_dir = temp.path().join("modules");
    fs::create_dir_all(&mod_dir).unwrap();

    // Скопируем helper.lua и languages/argparse.lua во временную директорию модулей
    let repo_modules = Path::new("modules");
    if repo_modules.join("helper.lua").exists() {
        fs::copy(repo_modules.join("helper.lua"), mod_dir.join("helper.lua")).unwrap();
    }
    if repo_modules.join("languages/argparse.lua").exists() {
        let _ = fs::create_dir_all(mod_dir.join("languages"));
        fs::copy(repo_modules.join("languages/argparse.lua"), mod_dir.join("languages/argparse.lua")).unwrap();
    }

    // Тестовый модуль: test_fuzzy.lua
    fs::write(
        mod_dir.join("test_fuzzy.lua"),
        r#"
        local helper = require("helper")
        local argparse = require("languages.argparse")
        local ctx = helper.ctx

        function main()
            -- 1. Тест нечеткого поиска названий модулей
            local modules = { "project", "pkg", "app", "box", "nix", "aider", "cmd", "host" }
            assert(helper.find_best_match("pckg", modules, 0.75) == "pkg", "pckg -> pkg")
            assert(helper.find_best_match("ap", modules, 0.75) == "app", "ap -> app")
            assert(helper.find_best_match("nx", modules, 0.75) == "nix", "nx -> nix")
            assert(helper.find_best_match("aidr", modules, 0.75) == "aider", "aidr -> aider")
            assert(helper.find_best_match("proj", modules, 0.75) == "project", "proj -> project")

            -- Несвязанные имена модулей не должны давать ложных срабатываний
            assert(helper.find_best_match("unknown_module_xyz", modules, 0.75) == nil, "unknown -> nil")

            -- 2. Тест названий аппов
            local apps = { "neovim", "terminal_chat", "system_monitor", "fzf_launcher" }
            assert(helper.find_best_match("neovm", apps, 0.75) == "neovim", "neovm -> neovim")
            assert(helper.find_best_match("sys_monitor", apps, 0.75) == "system_monitor" or helper.find_best_match("system_mon", apps, 0.75) == "system_monitor", "sys -> monitor")

            -- 3. Тест названий проектов
            local projects = { "SpaceInvaders", "DatabaseEngine", "WebScraper" }
            assert(helper.find_best_match("SpaceInvader", projects, 0.75) == "SpaceInvaders", "SpaceInvader -> SpaceInvaders")
            assert(helper.find_best_match("DataEngine", projects, 0.75) == "DatabaseEngine" or helper.find_best_match("DatabaseEng", projects, 0.75) == "DatabaseEngine", "DatabaseEngine")

            -- 4. Тест пакетов и менеджеров
            local mgrs = { "pacman", "flatpak", "nix", "distrobox", "cargo", "pipx" }
            assert(helper.find_best_match("pacmn", mgrs, 0.75) == "pacman", "pacmn -> pacman")
            assert(helper.find_best_match("fltpak", mgrs, 0.75) == "flatpak", "fltpak -> flatpak")

            -- 5. Тест флагов
            local flags = { "--all", "-a", "--deps", "--help", "-h", "--force", "-f" }
            assert(helper.fuzzy_match_flag("--al", flags, 0.75) == "--all", "--al -> --all")
            assert(helper.fuzzy_match_flag("--dep", flags, 0.75) == "--deps", "--dep -> --deps")
            assert(helper.fuzzy_match_flag("-hlp", flags, 0.75) == "--help", "-hlp -> --help")
            assert(helper.fuzzy_match_flag("--halp", flags, 0.75) == "--help", "--halp -> --help")

            -- Строки не должны превращаться во флаги
            assert(helper.fuzzy_match_flag("git", flags, 0.75) == nil, "git is string")
            assert(helper.fuzzy_match_flag("MyGame", flags, 0.75) == nil, "MyGame is string")

            -- 6. Проверка argparse c нечёткими флагами
            local cls = argparse.new({
                flags = {
                    all = { "-a", "--all", "--deps" },
                    force = { "-f", "--force" }
                }
            })
            local parsed = cls:parse({ "--al", "--forc", "my_package" })
            assert(parsed.flags.all == true, "argparse flag all matched via --al")
            assert(parsed.flags.force == true, "argparse flag force matched via --forc")
            assert(#parsed.args == 1 and parsed.args[1] == "my_package", "my_package kept as positional arg")

            ctx.success("fuzzy_tests_passed")
        end
    "#,
    )
    .unwrap();

    let orch = Orchestrator::new(Some(mod_dir), None).unwrap();
    let parsed = parse_pipeline_args(&["test_fuzzy".to_string()]);
    let res = orch.run_pipeline(&parsed).await;

    assert!(res.is_ok(), "Пайплайн с fuzzy тестами упал: {:?}", res);
    assert_eq!(res.unwrap().unwrap(), "fuzzy_tests_passed");
}

#[tokio::test]
async fn test_no_helper_lua_native_execution() {
    let temp = TestTempDir::new("grime_no_helper_test");
    let mod_dir = temp.path().join("modules");
    fs::create_dir_all(&mod_dir).unwrap();

    // Убеждаемся, что helper.lua физически отсутствует в тестовой директории
    assert!(!mod_dir.join("helper.lua").exists());

    // Скопируем реальный модуль cmd.lua
    let repo_modules = Path::new("modules");
    if repo_modules.join("cmd.lua").exists() {
        fs::copy(repo_modules.join("cmd.lua"), mod_dir.join("cmd.lua")).unwrap();
    }

    // Тестовый модуль native_test.lua, который не запрашивает helper
    fs::write(
        mod_dir.join("native_test.lua"),
        r#"
        local ctx = grime.ctx

        function main()
            assert(helper == nil, "helper is not required by default")
            assert(ctx ~= nil, "global/native ctx exists")
            assert(ctx.args ~= nil, "ctx.args exists")
            assert(ctx.paths ~= nil, "ctx.paths exists")
            assert(ctx.exists(".") == true, "ctx.exists works")
            assert(grime.str.to_snake_case("NativeRunner") == "native_runner")
            assert(grime.fs.normalize("./foo/../bar"):find("bar") ~= nil)

            local matched = grime.fuzzy.match_flag("--al", { "--all", "-a" }, 0.75)
            assert(matched == "--all")

            ctx.success("native_ok")
        end
        "#,
    )
    .unwrap();

    let orch = Orchestrator::new(Some(mod_dir), None).unwrap();
    let parsed = parse_pipeline_args(&["native_test".to_string()]);
    let res = orch.run_pipeline(&parsed).await;

    assert!(res.is_ok(), "Пайплайн без helper.lua упал: {:?}", res);
    assert_eq!(res.unwrap().unwrap(), "native_ok");
}

#[tokio::test]
async fn test_long_pipeline_multistep_chain() {
    let temp = TestTempDir::new("grime_long_pipeline_chain");
    let mod_dir = temp.path().join("modules");
    fs::create_dir_all(&mod_dir).unwrap();

    fs::write(
        mod_dir.join("step1.lua"),
        r#"
        function main()
            grime.ctx.success("alpha")
        end
        "#,
    )
    .unwrap();

    fs::write(
        mod_dir.join("step2.lua"),
        r#"
        function main()
            local inp = grime.ctx.input or grime.ctx.pipeline_input
            assert(inp == "alpha", "step2 expected alpha, got: " .. tostring(inp))
            grime.ctx.success(inp .. ":beta")
        end
        "#,
    )
    .unwrap();

    fs::write(
        mod_dir.join("step3.lua"),
        r#"
        function main()
            local inp = grime.ctx.input or grime.ctx.pipeline_input
            assert(inp == "alpha:beta", "step3 expected alpha:beta, got: " .. tostring(inp))
            grime.ctx.success(inp .. ":gamma")
        end
        "#,
    )
    .unwrap();

    fs::write(
        mod_dir.join("step4.lua"),
        r#"
        function main()
            local inp = grime.ctx.input or grime.ctx.pipeline_input
            assert(inp == "alpha:beta:gamma", "step4 expected alpha:beta:gamma, got: " .. tostring(inp))
            grime.ctx.success(inp .. ":delta")
        end
        "#,
    )
    .unwrap();

    let orch = Orchestrator::new(Some(mod_dir), None).unwrap();
    let parsed = parse_pipeline_args(&[
        "step1".to_string(),
        "->".to_string(),
        "step2".to_string(),
        "->".to_string(),
        "step3".to_string(),
        "->".to_string(),
        "step4".to_string(),
    ]);

    assert_eq!(parsed.steps.len(), 4);
    let res = orch.run_pipeline(&parsed).await;
    assert!(res.is_ok(), "Длинный конвейер завершился ошибкой: {:?}", res);
    assert_eq!(res.unwrap().unwrap(), "alpha:beta:gamma:delta");
}

#[tokio::test]
async fn test_command_list_and_aliases() {
    // 1. Проверка алиасов в парсере конвейера
    let p_list = parse_pipeline_args(&["list".to_string()]);
    assert_eq!(p_list.steps.len(), 1);
    assert_eq!(p_list.steps[0].module, "list");

    let p_ls = parse_pipeline_args(&["ls".to_string()]);
    assert_eq!(p_ls.steps.len(), 1);
    assert_eq!(p_ls.steps[0].module, "list");

    let p_modules = parse_pipeline_args(&["modules".to_string()]);
    assert_eq!(p_modules.steps.len(), 1);
    assert_eq!(p_modules.steps[0].module, "list");

    // 2. Исполнение модуля list.lua в локальной директории modules (если модуль присутствует)
    let local_mods = PathBuf::from("modules");
    if local_mods.join("list.lua").exists() {
        let orch = Orchestrator::new(Some(local_mods), None).unwrap();
        let res = orch.run_pipeline(&p_list).await;
        assert!(res.is_ok(), "Выполнение grime list завершилось ошибкой: {:?}", res);
        let ret = res.unwrap().unwrap();
        let count: usize = ret.parse().unwrap_or(0);
        assert!(count >= 10, "Ожидалось не менее 10 модулей, найдено: {}", count);
    }
}

#[tokio::test]
async fn test_pipeline_table_to_json_serialization() {
    let tmp = TestTempDir::new("grime_json_table");
    let mod_dir = tmp.path().join("modules");
    fs::create_dir_all(&mod_dir).unwrap();

    fs::write(
        mod_dir.join("producer_tbl.lua"),
        r#"
        function main()
            return {
                status = "ok",
                count = 42,
                items = { "apple", "banana" }
            }
        end
        "#,
    )
    .unwrap();

    fs::write(
        mod_dir.join("consumer_tbl.lua"),
        r#"
        function main()
            local raw = grime.ctx.input or grime.ctx.pipeline_input
            assert(raw and #raw > 0, "Ожидался JSON input")
            local parsed = grime.json.decode(raw)
            assert(parsed.status == "ok", "Ожидался status == ok")
            assert(parsed.count == 42, "Ожидался count == 42")
            assert(#parsed.items == 2, "Ожидалось 2 элемента")
            grime.ctx.success("verified:" .. parsed.items[1])
        end
        "#,
    )
    .unwrap();

    let orch = Orchestrator::new(Some(mod_dir), None).unwrap();
    let parsed = parse_pipeline_args(&["producer_tbl".to_string(), ":".to_string(), "consumer_tbl".to_string()]);
    let res = orch.run_pipeline(&parsed).await;
    assert!(res.is_ok(), "Пайплайн упал: {:?}", res);
    assert_eq!(res.unwrap().unwrap(), "verified:apple");
}

#[tokio::test]
async fn test_pipeline_stop_on_error_and_return_false() {
    let tmp = TestTempDir::new("grime_stop_err");
    let mod_dir = tmp.path().join("modules");
    fs::create_dir_all(&mod_dir).unwrap();

    fs::write(
        mod_dir.join("fail_step.lua"),
        r#"
        function main()
            return false
        end
        "#,
    )
    .unwrap();

    fs::write(
        mod_dir.join("never_step.lua"),
        r#"
        function main()
            grime.bus.set("modules.never.ran", true)
            grime.ctx.success("ran")
        end
        "#,
    )
    .unwrap();

    let orch = Orchestrator::new(Some(mod_dir.clone()), None).unwrap();

    // 1. Без force: конвейер останавливается на fail_step, never_step не выполняется
    let parsed_no_force = parse_pipeline_args(&["fail_step".to_string(), ":".to_string(), "never_step".to_string()]);
    let res = orch.run_pipeline(&parsed_no_force).await;
    assert!(res.is_err(), "Конвейер должен был вернуть ошибку без --force");
    assert!(!orch.state_bus().has("modules.never.ran"), "never_step не должен был запускаться!");

    // 2. С force: конвейер продолжает выполнение
    let parsed_force = parse_pipeline_args(&["--force".to_string(), "fail_step".to_string(), ":".to_string(), "never_step".to_string()]);
    assert!(parsed_force.force);
    let res_force = orch.run_pipeline(&parsed_force).await;
    assert!(res_force.is_ok(), "Конвейер с --force должен был продолжить работу");
    assert!(orch.state_bus().has("modules.never.ran"), "never_step должен был запуститься с --force!");
}

#[tokio::test]
async fn test_pipeline_input_special_characters_and_multiline() {
    let tmp = TestTempDir::new("grime_special_chars");
    let mod_dir = tmp.path().join("modules");
    fs::create_dir_all(&mod_dir).unwrap();

    fs::write(
        mod_dir.join("producer_multiline.lua"),
        r#"
        function main()
            local multiline = "Line 1 with spaces\nLine 2 with \"quotes\" and 'single'\nLine 3: 🦀 русские символы!"
            grime.ctx.success(multiline)
        end
        "#,
    )
    .unwrap();

    fs::write(
        mod_dir.join("consumer_multiline.lua"),
        r#"
        function main()
            local inp = grime.ctx.input or grime.ctx.pipeline_input
            assert(inp:find("Line 1 with spaces"), "Строка 1 не найдена")
            assert(inp:find("Line 2 with \"quotes\""), "Строка 2 не найдена")
            assert(inp:find("🦀 русские символы!"), "Строка 3 не найдена")
            grime.ctx.success("multiline_verified")
        end
        "#,
    )
    .unwrap();

    let orch = Orchestrator::new(Some(mod_dir), None).unwrap();
    let parsed = parse_pipeline_args(&["producer_multiline".to_string(), "->".to_string(), "consumer_multiline".to_string()]);
    let res = orch.run_pipeline(&parsed).await;
    assert!(res.is_ok(), "Многострочный пайплайн упал: {:?}", res);
    assert_eq!(res.unwrap().unwrap(), "multiline_verified");
}

#[tokio::test]
async fn test_project_overwrite_protection() {
    let tmp = TestTempDir::new("grime_proj_overwrite");
    let proj_dir = tmp.path().join("existing_project");
    fs::create_dir_all(&proj_dir).unwrap();
    fs::write(proj_dir.join("important_user_code.txt"), "DO NOT OVERWRITE ME!").unwrap();

    let local_mods = PathBuf::from("modules");
    if local_mods.exists() {
        let orch = Orchestrator::new(Some(local_mods), None).unwrap();

        // 1. Попытка создания без --force в существующей непустой директории должна вернуть ошибку
        let parsed_no_force = parse_pipeline_args(&[
            "project".to_string(),
            "init".to_string(),
            "cpp".to_string(),
            proj_dir.to_string_lossy().to_string(),
        ]);
        let res = orch.run_pipeline(&parsed_no_force).await;
        assert!(res.is_err(), "Инициализация поверх непустой директории без --force должна завершиться ошибкой!");
        let err_msg = res.unwrap_err();
        assert!(err_msg.contains("уже существует и не пуста"));

        // Файл пользователя не должен быть поврежден
        let content = fs::read_to_string(proj_dir.join("important_user_code.txt")).unwrap();
        assert_eq!(content, "DO NOT OVERWRITE ME!");

        // 2. С флагом --force инициализация проходит успешно
        let parsed_force = parse_pipeline_args(&[
            "--force".to_string(),
            "project".to_string(),
            "init".to_string(),
            "cpp".to_string(),
            proj_dir.to_string_lossy().to_string(),
        ]);
        assert!(parsed_force.force);
        let res_force = orch.run_pipeline(&parsed_force).await;
        assert!(res_force.is_ok(), "Инициализация с --force должна была выполниться: {:?}", res_force);
    }
}

#[tokio::test]
async fn test_module_returning_table_with_functions_not_leaked_as_json() {
    let tmp = TestTempDir::new("grime_module_leak");
    let mod_dir = tmp.path().join("modules");
    fs::create_dir_all(&mod_dir).unwrap();

    // Модуль, аналогичный app.lua: определяет main(), выводящую UI и завершающуюся с nil,
    // и возвращающий в конце скрипта таблицу функций модуля (для require).
    fs::write(
        mod_dir.join("ui_module.lua"),
        r#"
        local M = {
            helper_fn = function() return 123 end,
            another_fn = function() return "abc" end,
        }

        function main()
            -- Модуль просто выводит что-то в терминал и не возвращает полезных данных конвейеру
            print("Rendered UI successfully")
            return
        end

        M.main = main
        return M
        "#,
    )
    .unwrap();

    let orch = Orchestrator::new(Some(mod_dir), None).unwrap();
    let parsed = parse_pipeline_args(&["ui_module".to_string()]);
    let res = orch.run_pipeline(&parsed).await;
    assert!(res.is_ok(), "Выполнение ui_module упало: {:?}", res);
    let output = res.unwrap();
    assert!(
        output.is_none(),
        "Ожидался None, но получен паразитный вывод: {:?}",
        output
    );
}

#[tokio::test]
async fn test_stage3_optimizations_and_target_dir_and_cleanup_lifo() {
    let temp = TestTempDir::new("grime_stage3_test");
    let mod_dir = temp.path().join("modules");
    fs::create_dir_all(&mod_dir).unwrap();

    let accidental = temp.path().join("accidental_dir");
    fs::create_dir_all(&accidental).unwrap();

    // Модуль 1
    fs::write(
        mod_dir.join("step_one.lua"),
        r#"
        function main()
            grime.ctx.success("first_step_done")
        end
        "#,
    )
    .unwrap();

    // Модуль 2: возвращает путь к accidental, но НЕ меняет target_dir явно.
    // Так как это шаг 2 (step_idx == 1), target_dir НЕ должен случайно перезаписываться!
    fs::write(
        mod_dir.join("step_two.lua"),
        format!(
            r#"
            function main()
                grime.ctx.success("{path}")
            end
            "#,
            path = accidental.to_string_lossy().escape_default()
        ),
    )
    .unwrap();

    // Модуль 3: проверяем, что target_dir остался прежним
    fs::write(
        mod_dir.join("step_three.lua"),
        format!(
            r#"
            function main()
                local target = grime.ctx.target_dir
                local acc = "{path}"
                assert(target ~= acc, "target_dir was erroneously changed to output string: " .. tostring(target))
                grime.ctx.success("stage3_ok")
            end
            "#,
            path = accidental.to_string_lossy().escape_default()
        ),
    )
    .unwrap();

    let orch = Orchestrator::new(Some(mod_dir.clone()), None).unwrap();
    let parsed = parse_pipeline_args(&[
        "-p".to_string(),
        temp.path().to_string_lossy().to_string(),
        "step_one".to_string(),
        ":".to_string(),
        "step_two".to_string(),
        ":".to_string(),
        "step_three".to_string(),
    ]);

    let res = orch.run_pipeline(&parsed).await;
    assert!(res.is_ok(), "Пайплайн stage3 упал: {:?}", res);
    assert_eq!(res.unwrap().unwrap(), "stage3_ok");

    // Тест явного set_target_dir
    fs::write(
        mod_dir.join("step_explicit_dir.lua"),
        format!(
            r#"
            function main()
                grime.ctx.set_target_dir("{path}")
                grime.ctx.success("explicit_done")
            end
            "#,
            path = accidental.to_string_lossy().escape_default()
        ),
    )
    .unwrap();

    fs::write(
        mod_dir.join("step_check_explicit.lua"),
        format!(
            r#"
            function main()
                local target = grime.ctx.target_dir
                local acc = "{path}"
                assert(target == acc, "target_dir did not match explicit change: " .. tostring(target))
                grime.ctx.success("explicit_verified")
            end
            "#,
            path = grime::fs_ops::normalize_path(&accidental).to_string_lossy().escape_default()
        ),
    )
    .unwrap();

    let parsed_explicit = parse_pipeline_args(&[
        "step_explicit_dir".to_string(),
        ":".to_string(),
        "step_check_explicit".to_string(),
    ]);
    let res_explicit = orch.run_pipeline(&parsed_explicit).await;
    assert!(res_explicit.is_ok(), "Пайплайн с явным set_target_dir упал: {:?}", res_explicit);
    assert_eq!(res_explicit.unwrap().unwrap(), "explicit_verified");
}




