//! Articles: the lists, the personal feed, one article, and an author writing, editing and deleting their own.
mod data;
mod model;
pub mod route;
mod service;
pub(crate) mod sql;

pub(crate) use data::STATEMENTS;
pub use model::{Article, ArticleEnvelope, ArticleRow};
