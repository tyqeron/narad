use serde::{Deserialize, Serialize};
use std::collections::BTreeSet;

#[derive(Clone, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct Preferences {
    pub clipboard_sync: bool,
    pub shares: Vec<SharedFolder>,
    pub default_share_devices: BTreeSet<String>,
}
#[derive(Clone, Serialize, Deserialize)]
pub struct SharedFolder {
    pub id: String,
    pub label: String,
    pub path: String,
    pub documents: bool,
    pub upload: bool,
    #[serde(default)]
    pub devices: BTreeSet<String>,
}
