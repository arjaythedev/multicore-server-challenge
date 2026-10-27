//! Public profiles and who follows whom.
mod data;
mod model;
pub mod route;
mod service;

pub(crate) use data::STATEMENTS;
pub use model::Profile;
