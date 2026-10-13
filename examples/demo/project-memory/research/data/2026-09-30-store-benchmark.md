---
title: 存储引擎选型基准
date: 2026-09-30
status: concluded
questions: PostgreSQL 与 MySQL 在本项目的读写形态下差多少
leads-to: [DEC-001]
---
结论：两者常规读写相当；JSONB 的查询与索引能力决定选 PostgreSQL。
