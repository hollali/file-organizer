use clap::Parser;
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime};
use walkdir::WalkDir;

#[derive(Parser, Debug)]
#[command(name = "organize-rs", version = "1.3.1", about = "Fast file organizer (Rust core)")]
struct Args {
    #[arg(default_value = ".")]
    directory: String,
    #[arg(short = 'r', long = "recursive")]
    recursive: bool,
    #[arg(short = 'n', long = "dry-run")]
    dry_run: bool,
    #[arg(short = 't', long = "target")]
    target: Option<String>,
    #[arg(short = 'H', long = "hidden")]
    hidden: bool,
    #[arg(short = 'T', long = "tv")]
    tv: bool,
    #[arg(long = "smart")]
    smart: bool,
    #[arg(long = "by-date")]
    by_date: bool,
    #[arg(long = "rename")]
    rename: bool,
    #[arg(long = "json")]
    json: bool,
    #[arg(long = "undo")]
    undo: bool,
    #[arg(long = "min-size")]
    min_size: Option<String>,
    #[arg(long = "max-size")]
    max_size: Option<String>,
    #[arg(long = "older-than")]
    older_than: Option<u64>,
    #[arg(long = "include", action = clap::ArgAction::Append)]
    include: Vec<String>,
    #[arg(long = "exclude", action = clap::ArgAction::Append)]
    exclude: Vec<String>,
    #[arg(long = "rules")]
    rules: Option<String>,
}

#[derive(Serialize, Deserialize, Clone)]
struct Entry {
    src: String,
    dest: String,
}

#[derive(Serialize, Deserialize)]
struct Log {
    target: String,
    entries: Vec<Entry>,
}

fn category_for(ext: &str) -> &'static str {
    let e = ext.to_lowercase();
    match e.as_str() {
        "jpg" | "jpeg" | "png" | "gif" | "bmp" | "tiff" | "tif" | "webp" | "svg" | "heic" | "heif" | "avif" | "raw" | "cr2" | "nef" | "dng" => "Images",
        "pdf" | "doc" | "docx" | "txt" | "rtf" | "odt" | "md" | "markdown" | "xls" | "xlsx" | "ods" | "ppt" | "pptx" | "odp" | "csv" | "epub" => "Documents",
        "mp4" | "mkv" | "avi" | "mov" | "wmv" | "flv" | "webm" | "m4v" | "mpg" | "mpeg" | "3gp" | "ogv" => "Videos",
        "mp3" | "wav" | "flac" | "aac" | "ogg" | "m4a" | "wma" | "opus" | "mid" | "midi" => "Audio",
        "zip" | "tar" | "gz" | "bz2" | "xz" | "7z" | "rar" | "tgz" | "tbz2" | "txz" | "zst" => "Archives",
        "iso" | "img" | "dmg" => "Disk Images",
        "sh" | "bash" | "zsh" | "fish" | "py" | "js" | "jsx" | "ts" | "tsx" | "json" | "yaml" | "yml" | "toml" | "xml" | "html" | "htm" | "css" | "scss" | "sass" | "less" | "php" | "rb" | "go" | "rs" | "java" | "c" | "h" | "cpp" | "hpp" | "cs" | "swift" | "kt" | "kts" | "sql" | "lua" | "pl" | "r" | "m" | "mm" | "gradle" => "Code",
        "ttf" | "otf" | "woff" | "woff2" => "Fonts",
        "exe" | "msi" | "deb" | "rpm" | "appimage" | "apk" | "flatpak" | "snap" => "Executables",
        _ => "Other",
    }
}

fn parse_size(s: &str) -> u64 {
    let s = s.trim();
    let (num, unit) = if let Some(i) = s.find(|c: char| !c.is_ascii_digit()) {
        (&s[..i], &s[i..])
    } else {
        (s, "")
    };
    let n: u64 = num.parse().unwrap_or(0);
    match unit.to_lowercase().as_str() {
        "k" => n * 1024,
        "m" => n * 1048576,
        "g" => n * 1073741824,
        _ => n,
    }
}

fn unique_path(dest: &Path) -> PathBuf {
    if !dest.exists() {
        return dest.to_path_buf();
    }
    let parent = dest.parent().unwrap_or(Path::new("."));
    let stem = dest.file_stem().map(|s| s.to_string_lossy().to_string()).unwrap_or_default();
    let ext = dest.extension().map(|e| format!(".{}", e.to_string_lossy())).unwrap_or_default();
    let mut i = 1;
    loop {
        let cand = parent.join(format!("{} ({}){}", stem, i, ext));
        if !cand.exists() {
            return cand;
        }
        i += 1;
    }
}

fn rename_basename(name: &str) -> String {
    let (base, ext) = if let Some(i) = name.rfind('.') {
        if i > 0 {
            (&name[..i], &name[i..])
        } else {
            (name, "")
        }
    } else {
        (name, "")
    };
    let mut b = base.to_lowercase().replace(' ', "_");
    while b.contains("__") {
        b = b.replace("__", "_");
    }
    b = b.trim_matches('_').to_string();
    format!("{}{}", b, ext)
}

fn is_hidden(p: &Path) -> bool {
    p.file_name().map(|n| n.to_string_lossy().starts_with('.')).unwrap_or(false)
}

fn detect_episode(name: &str) -> Option<(String, u32)> {
    // returns (show, season) for common patterns
    let base = name.rsplit('/').next().unwrap_or(name);
    let base = base.rsplit('.').next().map(|_| base).unwrap_or(base); // keep ext? we strip below
    let stem = if let Some(i) = base.rfind('.') { &base[..i] } else { base };
    // patterns: Show.S01E02, Show.1x03, Show Season 01 Episode 02
    // Use simple regex-like manual parsing via splitting
    // Try S season E episode
    for (i, c) in stem.char_indices() {
        if (c == 'S' || c == 's') && i + 3 < stem.len() {
            let rest = &stem[i+1..];
            if let Some(e) = rest.find(|ch: char| ch == 'E' || ch == 'e') {
                if e >= 1 && e <= 2 {
                    let season_str = &rest[..e];
                    if season_str.chars().all(|ch| ch.is_ascii_digit()) {
                        let show = stem[..i].trim_matches(|ch: char| ch == '.' || ch == '_' || ch == '-' || ch == ' ');
                        if !show.is_empty() {
                            if let Ok(season) = season_str.parse::<u32>() {
                                return Some((show.to_string(), season));
                            }
                        }
                    }
                }
            }
        }
    }
    // N x M
    // find 'x' or 'X' with digits around
    for (i, c) in stem.char_indices() {
        if c == 'x' || c == 'X' {
            if i > 0 && i + 1 < stem.len() {
                let left = &stem[..i];
                let right = &stem[i+1..];
                let ltrim: String = left.chars().rev().take_while(|ch| ch.is_ascii_digit()).collect::<String>().chars().rev().collect();
                let rtrim: String = right.chars().take_while(|ch| ch.is_ascii_digit()).collect();
                if !ltrim.is_empty() && !rtrim.is_empty() {
                    if let (Ok(season), Ok(_ep)) = (ltrim.parse::<u32>(), rtrim.parse::<u32>()) {
                        let show_part = &left[..left.len()-ltrim.len()];
                        let show = show_part.trim_matches(|ch: char| ch == '.' || ch == '_' || ch == '-' || ch == ' ');
                        if !show.is_empty() {
                            return Some((show.to_string(), season));
                        }
                    }
                }
            }
        }
    }
    None
}

fn main() {
    let args = Args::parse();
    let dir = fs::canonicalize(&args.directory).unwrap_or_else(|_| PathBuf::from(&args.directory));
    let target = if let Some(t) = &args.target {
        let p = PathBuf::from(t);
        if !p.exists() { fs::create_dir_all(&p).ok(); }
        fs::canonicalize(&p).unwrap_or(p)
    } else {
        dir.clone()
    };

    // undo
    if args.undo {
        let mut logs: Vec<PathBuf> = fs::read_dir(&dir)
            .ok()
            .map(|rd| rd.filter_map(|e| e.ok()).map(|e| e.path()).filter(|p| {
                p.file_name().map(|n| n.to_string_lossy().starts_with(".organize-log-") && n.to_string_lossy().ends_with(".log")).unwrap_or(false)
            }).collect())
            .unwrap_or_default();
        logs.sort();
        if logs.is_empty() {
            println!("no organize log found in {}", dir.display());
            return;
        }
        let latest = logs.last().unwrap();
        let content = fs::read_to_string(latest).unwrap_or_default();
        if let Ok(log) = serde_json::from_str::<Log>(&content) {
            for e in log.entries.iter().rev() {
                let src = PathBuf::from(&e.src);
                let dest = PathBuf::from(&e.dest);
                if !dest.exists() { println!("skip (missing): {}", dest.display()); continue; }
                if let Some(parent) = src.parent() { fs::create_dir_all(parent).ok(); }
                if src.exists() { println!("skip (target exists): {}", src.display()); continue; }
                if fs::rename(&dest, &src).is_ok() {
                    println!("restored: {}", src.display());
                } else {
                    println!("skip (move failed): {}", dest.display());
                }
            }
        }
        let _ = fs::remove_file(latest);
        println!("Undo complete.");
        return;
    }

    // collect files
    let min_size = args.min_size.as_ref().map(|s| parse_size(s));
    let max_size = args.max_size.as_ref().map(|s| parse_size(s));
    let now = SystemTime::now();

    let mut files: Vec<PathBuf> = Vec::new();
    let walker = if args.recursive {
        WalkDir::new(&dir).into_iter()
    } else {
        // only top-level
        WalkDir::new(&dir).max_depth(1).into_iter()
    };
    for entry in walker.filter_map(|e| e.ok()) {
        let p = entry.path();
        if p == dir { continue; }
        if !entry.file_type().is_file() { continue; }
        if !args.hidden && is_hidden(p) { continue; }
        // prune category dirs when recursive
        if args.recursive {
            if let Ok(rel) = p.strip_prefix(&dir) {
                let first = rel.components().next().map(|c| c.as_os_str().to_string_lossy().to_string()).unwrap_or_default();
                let cats = ["Images","Documents","Videos","Audio","Archives","Disk Images","Code","Fonts","Executables","Other","Folders"];
                if cats.contains(&first.as_str()) && target != dir {
                    // skip files already under target categories when target differs? keep simple
                }
            }
        }
        // include/exclude
        let name = p.file_name().unwrap_or_default().to_string_lossy();
        if !args.include.is_empty() {
            let mut ok = false;
            for g in &args.include { if glob_match(g, &name) { ok = true; } }
            if !ok { continue; }
        }
        if !args.exclude.is_empty() {
            let mut skip = false;
            for g in &args.exclude { if glob_match(g, &name) { skip = true; } }
            if skip { continue; }
        }
        if let Ok(meta) = fs::metadata(p) {
            if let Some(ms) = min_size { if meta.len() < ms { continue; } }
            if let Some(xs) = max_size { if meta.len() > xs { continue; } }
            if let Some(days) = args.older_than {
                if let Ok(mtime) = meta.modified() {
                    if let Ok(age) = now.duration_since(mtime) {
                        if age < Duration::from_secs(days * 86400) { continue; }
                    }
                }
            }
        }
        files.push(p.to_path_buf());
    }

    // rules
    let mut rule_pats: Vec<String> = Vec::new();
    let mut rule_dests: Vec<String> = Vec::new();
    if let Some(rf) = &args.rules {
        if let Ok(content) = fs::read_to_string(rf) {
            for line in content.lines() {
                let line = line.trim();
                if line.is_empty() || line.starts_with('#') { continue; }
                if let Some(idx) = line.find("->").or_else(|| line.find("=>")) {
                    let pat = line[..idx].trim().to_string();
                    let dst = line[idx+2..].trim().to_string();
                    rule_pats.push(pat);
                    rule_dests.push(dst);
                }
            }
        }
    }

    let mut counts: BTreeMap<String, (u64, u64)> = BTreeMap::new();
    let mut moved_count = 0u64;
    let mut moved_bytes = 0u64;
    let mut entries: Vec<Entry> = Vec::new();

    for f in &files {
        let name = f.file_name().unwrap_or_default().to_string_lossy().to_string();
        let ext = f.extension().map(|e| e.to_string_lossy().to_string()).unwrap_or_default();
        // rule
        let mut cat: Option<String> = None;
        for (i, pat) in rule_pats.iter().enumerate() {
            if glob_match(pat, &name) {
                cat = Some(rule_dests[i].clone());
                break;
            }
        }
        let is_video = matches!(ext.to_lowercase().as_str(), "mp4"|"mkv"|"avi"|"mov"|"wmv"|"flv"|"webm"|"m4v"|"mpg"|"mpeg"|"3gp"|"ogv");
    let is_image = matches!(ext.to_lowercase().as_str(), "jpg"|"jpeg"|"png"|"gif"|"bmp"|"tiff"|"tif"|"webp"|"svg"|"heic"|"heif"|"avif"|"raw");
    let is_doc = matches!(ext.to_lowercase().as_str(), "pdf"|"doc"|"docx"|"txt"|"rtf"|"odt"|"md"|"markdown");
    if args.tv && is_video && detect_episode(&name).is_none() {
        continue;
    }
    let mut cat = cat.unwrap_or_else(|| {
        if args.smart {
            if is_video {
                if let Some((show, season)) = detect_episode(&name) {
                    return format!("Videos/{}/Season {:02}", show, season);
                }
                return "Videos".to_string();
            }
            if is_image { return "Pictures".to_string(); }
            if is_doc { return "Documents".to_string(); }
        }
        category_for(&ext).to_string()
    });
    if args.tv && is_video {
        if let Some((show, season)) = detect_episode(&name) {
            cat = format!("Videos/{}/Season {:02}", show, season);
        }
    }
        if args.by_date {
            if let Ok(meta) = fs::metadata(f) {
                if let Ok(mtime) = meta.modified() {
                    // convert to local-ish UTC date components
                    let secs = mtime.duration_since(SystemTime::UNIX_EPOCH).unwrap_or_default().as_secs();
                    let days = secs / 86400;
                    // approximate year/month using civil date algorithm
                    let (y, m, _d) = civil_from_days(days as i64);
                    cat = format!("{}/{} /{}", cat, y, format!("{:02}", m));
                    cat = cat.replace(" /", "/");
                }
            }
        }
        let mut new_name = name.clone();
        if args.rename {
            new_name = rename_basename(&new_name);
        }
        let dest_dir = target.join(&cat);
        let mut dest = dest_dir.join(&new_name);
        if dest == *f {
            println!("already organized: {}", f.display());
            continue;
        }
        dest = unique_path(&dest);

        if args.dry_run {
            println!("would move: {} -> {}", f.display(), dest.display());
        } else {
            fs::create_dir_all(&dest_dir).ok();
            if fs::rename(f, &dest).is_ok() {
                println!("moved: {} -> {}", f.display(), dest.display());
            } else {
                eprintln!("failed: {}", f.display());
                continue;
            }
        }
        entries.push(Entry { src: f.to_string_lossy().to_string(), dest: dest.to_string_lossy().to_string() });
        let top = cat.split('/').next().unwrap_or(&cat).to_string();
        let e = counts.entry(top).or_insert((0, 0));
        let meta_len = fs::metadata(f).map(|m| m.len()).unwrap_or(0);
        e.0 += 1;
        e.1 += meta_len;
        moved_count += 1;
        moved_bytes += meta_len;
    }

    if !args.dry_run && !entries.is_empty() {
        let log_name = format!(".organize-log-{}.log", chrono_now());
        let log_path = dir.join(&log_name);
        let log = Log { target: target.to_string_lossy().to_string(), entries };
        if let Ok(s) = serde_json::to_string_pretty(&log) {
            let _ = fs::write(&log_path, s);
            println!("Log: {} (use --undo to revert)", log_path.display());
        }
    } else if args.dry_run {
        // entries not needed
    }

    if args.json {
        // build json summary manually
        let mut cats = serde_json::Map::new();
        for (k, (c, b)) in &counts {
            let mut o = serde_json::Map::new();
            o.insert("count".into(), serde_json::json!(c));
            o.insert("bytes".into(), serde_json::json!(b));
            cats.insert(k.clone(), serde_json::Value::Object(o));
        }
        let mut summary = serde_json::Map::new();
        summary.insert("dry_run".into(), serde_json::json!(args.dry_run));
        summary.insert("moved".into(), serde_json::json!(moved_count));
        summary.insert("moved_bytes".into(), serde_json::json!(moved_bytes));
        summary.insert("categories".into(), serde_json::Value::Object(cats));
        println!("{}", serde_json::to_string(&summary).unwrap_or_default());
    } else {
        if args.dry_run { println!("Summary (dry run):"); } else { println!("Summary:"); }
        for (k, (c, b)) in &counts {
            let hs = if *b >= 1048576 {
                format!("{:.1} MiB", *b as f64 / 1048576.0)
            } else if *b >= 1024 {
                format!("{:.1} KiB", *b as f64 / 1024.0)
            } else {
                format!("{} B", b)
            };
            println!("  {:<20} {} files  {}", k, c, hs);
        }
        println!("  {:<20} {} files", "Total", moved_count);
    }
}

fn chrono_now() -> String {
    // simple timestamp without chrono dependency
    use std::time::{SystemTime, UNIX_EPOCH};
    let secs = SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_secs();
    // convert to UTC-ish YYYYMMDD-HHMMSS (approx, not timezone aware)
    let t = secs;
    let sec = t % 60;
    let min = (t / 60) % 60;
    let hour = (t / 3600) % 24;
    let days = t / 86400;
    // civil date from days (Howard Hinnant algorithm)
    let (y, m, d) = civil_from_days(days as i64);
    format!("{:04}{:02}{:02}-{:02}{:02}{:02}", y, m, d, hour, min, sec)
}

fn civil_from_days(z: i64) -> (i64, u32, u32) {
    let z = z + 719468;
    let era = if z >= 0 { z } else { z - 146096 } / 146097;
    let doe = z - era * 146097;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = if m <= 2 { y + 1 } else { y };
    (y, m as u32, d as u32)
}

fn glob_match(pattern: &str, name: &str) -> bool {
    // simple glob with * and ?
    let mut pi = 0;
    let mut ni = 0;
    let p: Vec<char> = pattern.chars().collect();
    let n: Vec<char> = name.chars().collect();
    let mut star: Option<usize> = None;
    let mut match_idx = 0;
    while ni < n.len() {
        if pi < p.len() && (p[pi] == n[ni] || p[pi] == '?') {
            pi += 1;
            ni += 1;
        } else if pi < p.len() && p[pi] == '*' {
            star = Some(pi);
            match_idx = ni;
            pi += 1;
        } else if let Some(s) = star {
            pi = s + 1;
            match_idx += 1;
            ni = match_idx;
        } else {
            return false;
        }
    }
    while pi < p.len() && p[pi] == '*' {
        pi += 1;
    }
    pi == p.len()
}
