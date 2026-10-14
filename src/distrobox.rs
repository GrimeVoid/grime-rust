use std::process::Command;

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct DistroboxContainer {
    pub id: String,
    pub name: String,
    pub status: String,
    pub image: String,
}

pub fn get_distrobox_containers() -> Vec<DistroboxContainer> {
    let output = match Command::new("distrobox")
        .arg("list")
        .arg("--no-color")
        .output()
    {
        Ok(out) => out,
        Err(_) => return Vec::new(),
    };

    if !output.status.success() {
        return Vec::new();
    }

    let text = String::from_utf8_lossy(&output.stdout);
    let mut containers = Vec::new();

    for line in text.lines().skip(1) {
        let line = line.trim();
        if line.is_empty() {
            continue;
        }

        let parts: Vec<&str> = line.split('|').map(|p| p.trim()).collect();
        if parts.len() >= 3 && parts[0] != "ID" {
            let id = parts[0].to_string();
            let name = parts[1].to_string();
            let status = parts[2].to_string();
            let image = if parts.len() >= 4 {
                parts[3].to_string()
            } else {
                String::new()
            };

            containers.push(DistroboxContainer {
                id,
                name,
                status,
                image,
            });
        }
    }

    containers
}

pub fn get_default_box_name(
    containers: &[DistroboxContainer],
    configured_default: Option<&str>,
) -> Option<String> {
    if containers.is_empty() {
        return None;
    }

    // 1. По значению из конфига
    if let Some(def) = configured_default {
        if let Some(found) = containers.iter().find(|c| c.name == def) {
            return Some(found.name.clone());
        }
    }

    // 2. Ищем запущенный контейнер
    for c in containers {
        let st = c.status.to_lowercase();
        if st.contains("up") || st.contains("running") {
            return Some(c.name.clone());
        }
    }

    // 3. Первый контейнер
    Some(containers[0].name.clone())
}
