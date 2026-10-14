//! Модуль форматирования пользовательского интерфейса для Lua (grime.ui).
//!
//! Обеспечивает цветной консольный вывод, печать таблиц и многоколоночное форматирование.

use colored::Colorize;
use mlua::{Lua, Table};

/// Регистрирует подтаблицу `grime.ui`.
pub fn register_ui_api(lua: &Lua, grime_tbl: &Table) -> Result<(), mlua::Error> {
    let ui_tbl = lua.create_table()?;

    // grime.ui.log(msg)
    ui_tbl.set(
        "log",
        lua.create_function(|_, msg: String| {
            eprintln!("{} {}", "[Grime]".cyan().bold(), msg);
            Ok(())
        })?,
    )?;

    // grime.ui.error(msg)
    ui_tbl.set(
        "error",
        lua.create_function(|_, msg: String| {
            eprintln!("{} {}", "[Grime Error]".red().bold(), msg);
            Ok(())
        })?,
    )?;

    // grime.ui.warn(msg)
    ui_tbl.set(
        "warn",
        lua.create_function(|_, msg: String| {
            eprintln!("{} {}", "[Grime Warning]".yellow().bold(), msg);
            Ok(())
        })?,
    )?;

    // grime.ui.success(msg)
    ui_tbl.set(
        "success",
        lua.create_function(|_, msg: String| {
            eprintln!("{} {}", "[Grime Success]".green().bold(), msg);
            Ok(())
        })?,
    )?;

    // grime.ui.print_table(rows, headers)
    ui_tbl.set(
        "print_table",
        lua.create_function(|_, (rows, headers): (Vec<Vec<String>>, Option<Vec<String>>)| {
            let mut col_widths: Vec<usize> = Vec::new();
            if let Some(ref hdrs) = headers {
                for (col_idx, h) in hdrs.iter().enumerate() {
                    if col_widths.len() <= col_idx {
                        col_widths.push(h.chars().count());
                    } else {
                        col_widths[col_idx] = col_widths[col_idx].max(h.chars().count());
                    }
                }
            }
            for row in &rows {
                for (col_idx, cell) in row.iter().enumerate() {
                    let cell_len = cell.chars().count();
                    if col_widths.len() <= col_idx {
                        col_widths.push(cell_len);
                    } else {
                        col_widths[col_idx] = col_widths[col_idx].max(cell_len);
                    }
                }
            }

            if let Some(ref hdrs) = headers {
                let mut header_line = String::new();
                for (i, h) in hdrs.iter().enumerate() {
                    let width = col_widths.get(i).copied().unwrap_or(h.len());
                    header_line.push_str(&format!("{:<width$}  ", h, width = width));
                }
                println!("{}", header_line.bold());
                let sep_len: usize = col_widths.iter().map(|w| w + 2).sum();
                println!("{}", "-".repeat(sep_len).dimmed());
            }

            for row in &rows {
                let mut row_line = String::new();
                for (i, cell) in row.iter().enumerate() {
                    let width = col_widths.get(i).copied().unwrap_or(cell.len());
                    row_line.push_str(&format!("{:<width$}  ", cell, width = width));
                }
                println!("{}", row_line);
            }
            Ok(())
        })?,
    )?;

    // grime.ui.format_columns(items, max_width) -> table
    ui_tbl.set(
        "format_columns",
        lua.create_function(|lua, (items, max_width): (Vec<String>, Option<usize>)| {
            let limit = max_width.unwrap_or(80);
            let max_item_len = items.iter().map(|s| s.chars().count()).max().unwrap_or(0);
            let col_width = max_item_len + 2;
            let num_cols = (limit / col_width.max(1)).max(1);
            let mut out_lines = Vec::new();

            let mut current_line = String::new();
            let mut col_count = 0;
            for item in &items {
                if col_count >= num_cols {
                    out_lines.push(current_line);
                    current_line = String::new();
                    col_count = 0;
                }
                current_line.push_str(&format!("{:<width$}", item, width = col_width));
                col_count += 1;
            }
            if !current_line.is_empty() {
                out_lines.push(current_line);
            }

            let res_tbl = lua.create_table()?;
            for (idx, l) in out_lines.into_iter().enumerate() {
                res_tbl.set(idx + 1, l)?;
            }
            Ok(res_tbl)
        })?,
    )?;

    grime_tbl.set("ui", ui_tbl)?;
    Ok(())
}
