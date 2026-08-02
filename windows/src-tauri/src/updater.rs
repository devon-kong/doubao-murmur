//! Checks GitHub for a newer release. Mirrors UpdateChecker.swift: request
//! /releases/latest without following the redirect and read the tag out of the
//! Location header, which avoids the API and its rate limit.

use std::time::Duration;

use crate::config;

pub struct Release {
    pub version: String,
    pub url: String,
}

pub fn check(current: &str) -> Result<Option<Release>, String> {
    let url = format!("https://github.com/{}/releases/latest", config::GITHUB_REPO);

    let agent = ureq::AgentBuilder::new()
        .redirects(0)
        .timeout(Duration::from_secs(10))
        .build();

    let response = match agent.get(&url).call() {
        Ok(response) => response,
        // With redirects disabled ureq surfaces the 3xx as an error.
        Err(ureq::Error::Status(code, response)) if (300..400).contains(&code) => response,
        Err(e) => return Err(e.to_string()),
    };

    let Some(location) = response.header("location") else {
        return Err("GitHub 没有返回 Location 头".to_string());
    };

    let tag = location.trim_end_matches('/').rsplit('/').next().unwrap_or("");
    if tag.is_empty() {
        return Err("无法从 Location 中解析版本号".to_string());
    }

    let remote = tag.strip_prefix('v').unwrap_or(tag);
    Ok(is_newer(remote, current).then(|| Release {
        version: remote.to_string(),
        url: location.to_string(),
    }))
}

/// Numeric dotted-version comparison.
pub fn is_newer(remote: &str, current: &str) -> bool {
    let left = parse(remote);
    let right = parse(current);

    for index in 0..left.len().max(right.len()) {
        let a = left.get(index).copied().unwrap_or(0);
        let b = right.get(index).copied().unwrap_or(0);
        if a != b {
            return a > b;
        }
    }
    false
}

fn parse(version: &str) -> Vec<u32> {
    version
        .split('.')
        .map(|part| {
            part.chars()
                .take_while(char::is_ascii_digit)
                .collect::<String>()
                .parse()
                .unwrap_or(0)
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn detects_upgrades() {
        assert!(is_newer("1.0.1", "1.0.0"));
        assert!(is_newer("1.1.0", "1.0.9"));
        assert!(is_newer("2.0.0", "1.9.9"));
        assert!(is_newer("1.2", "1.1.9"));
    }

    #[test]
    fn rejects_same_or_older() {
        assert!(!is_newer("1.0.0", "1.0.0"));
        assert!(!is_newer("1.0.0", "1.0.1"));
        assert!(!is_newer("1.0", "1.0.0"));
        assert!(!is_newer("0.9.9", "1.0.0"));
    }

    #[test]
    fn ignores_non_numeric_suffixes() {
        assert!(is_newer("1.2.0", "1.1.0-beta"));
    }
}
