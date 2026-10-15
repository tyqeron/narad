pub mod identity;
pub mod model;
pub mod policy;
pub mod storage;
pub mod transfer;

pub const PROTOCOL_VERSION: u16 = 1;
pub const CHUNK_SIZE: usize = 64 * 1024;
pub const MAX_FRAME: usize = 128 * 1024;

#[cfg(windows)]
pub mod windows;
