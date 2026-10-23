# AGENT.md: Python Raw-Socket Conduit Server Blueprint

This document serves as the core architectural specification and design reference for building a high-performance, ultra-low-overhead implementation of the RealWorld "Conduit" API for the **Multicore Server Challenge** (`arjaythedev/multicore-server-challenge`).

---

## 1. Core Objectives & Constraints

- **Platform Target:** Ubuntu 24.04 x86_64 running on **8 vCPUs and 16 GB RAM**.
- **Database:** PostgreSQL 18 running locally on the same box (`max_connections = 100`, fixed schema).
- **Performance Goal:** Maximize throughput and concurrency while minimizing memory overhead and CPU context switching.
- **Correctness:** Must pass 100% of the conformance test suite (`test/run.sh`).

---

## 2. Architectural Principles: Hexagonal Architecture (Ports & Adapters)

To ensure clean separation of concerns, testability, and strict decoupling, the codebase is organized around Hexagonal Architecture:

1. **Domain (`domain/`):** Pure Python business models, frozen dataclasses (`@dataclass(frozen=True)`), and business logic services. **Zero external dependencies** (no HTTP, no database drivers, no framework imports).
2. **Ports (`ports/`):** Interface contracts defined using Python `Protocol` classes for inbound requests and outbound infrastructure (databases, crypto, token validation).
3. **Adapters (`adapters/`):** Concrete implementations of ports:
   - **Inbound (`adapters/inbound/`):** Non-blocking raw socket server (`selectors`/epoll), decorator-based router (`SocketRouter`), and endpoint controllers.
   - **Outbound (`adapters/outbound/`):** PostgreSQL repository adapter (`psycopg3`) and cryptographic/JWT adapter (`bcrypt`, `PyJWT`).
4. **Composition Root (`main.py`):** Wires infrastructure adapters, connection pools, and routers together at startup.

---

## 3. Key Design Choices & Rationale

### A. Business Logic Isolation in the Domain Layer

- **Choice:** All validation rules, slug generation, authorization invariants, and core domain transformations live exclusively inside `domain/services.py` and `domain/models.py`.
- **Why:** Decouples business rules from HTTP transport, database drivers, or JSON parsing, ensuring pure functions that are easily unit-tested and fully independent.

### B. Bypassing Frameworks for Raw Sockets & Epoll

- **Choice:** Implement a non-blocking TCP socket server using Python's `selectors` module (backed by Linux `epoll`) rather than standard frameworks like FastAPI, Flask, or Django.
- **Why:** Eliminates heavy framework middleware and request context overhead, giving us total control over keep-alive socket lifecycles, HTTP/1.1 byte-streams, and memory footprints.

### C. Decorator Routing with Frozen Dataclasses

- **Choice:** A lightweight custom router using function decorators (`@router.get`, `@router.post`) that accept raw requests and return **frozen dataclasses**.
- **Why:** Frozen dataclasses provide type safety, structural immutability, and clean domain modeling. The router automatically inspects return values, serializes them via `dataclasses.asdict()` and `json.dumps()`, and builds optimized HTTP/1.1 byte responses.

### D. Bounded Connection Pooling

- **Choice:** Utilize `psycopg_pool.ConnectionPool` bounded strictly between **`5` min and `30` max connections**.
- **Why:** PostgreSQL is configured with a hard limit of `max_connections = 100` on the challenge box. An optimal bounded pool prevents connection exhaustion while eliminating per-request handshake overhead.

### E. Strict Adherence to Challenge Rules

- **No Cross-Request Caching (Rule 5):** Every request queries PostgreSQL directly. No memoization of JWTs, bcrypt hashes, or query results.
- **Real Security (Rule 7):** Passwords are verified against bcrypt cost 10 hashes; every JWT token signature (`HS256`) and expiration is evaluated dynamically.
- **Direct vs. Nginx (`Front: direct`):** Designed to support direct serving on `0.0.0.0:80` to reclaim CPU cycles, relying on non-blocking epoll selectors to handle tens of thousands of concurrent keep-alive sockets.

---

## 4. Project Directory Structure

```text
conduit_server/
├── domain/
│   ├── models.py            # Frozen dataclasses for entities and responses
│   └── services.py          # Pure business logic, validation rules & slug generation
├── ports/
│   ├── inbound.py           # Inbound handler protocols
│   └── outbound.py          # Database & Crypto port contracts
├── adapters/
│   ├── inbound/
│   │   ├── socket_server.py # Non-blocking epoll raw socket server
│   │   ├── router.py        # Decorator router & JSON/dataclass serializer
│   │   └── controllers.py   # Endpoint handlers utilizing domain services
│   └── outbound/
│       ├── pg_repository.py # Psycopg3 PostgreSQL adapter
│       └── crypto_adapter.py# Bcrypt & JWT verification adapter
└── main.py                  # Composition root & process bootstrap
```
