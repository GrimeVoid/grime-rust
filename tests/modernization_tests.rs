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
