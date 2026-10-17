use serde::{Deserialize, Serialize};

#[derive(Clone, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct Preferences {
    pub clipboard_sync: bool,
    pub shares: Vec<SharedFolder>,
}
#[derive(Clone, Serialize, Deserialize)]
pub struct SharedFolder {
    pub id: String,
    pub label: String,
    pub path: String,
    pub documents: bool,
    pub upload: bool,
}
